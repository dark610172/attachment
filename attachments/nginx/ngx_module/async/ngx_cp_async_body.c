#include "ngx_cp_async_body.h"

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <ngx_event.h>
#include <errno.h>
#include <stddef.h>

#include "ngx_cp_async_core.h"
#include "ngx_cp_async_ctx_validation.h"
#include "ngx_cp_async_sender.h"
#include "../ngx_cp_hooks.h"
#include "../ngx_cp_initializer.h"
#include "../ngx_cp_utils.h"
#include "../ngx_cp_metric.h"
#include "../ngx_http_cp_attachment_module.h"
#include "../ngx_cp_failing_state.h"
#include "../ngx_cp_compression.h"
#include "../ngx_cp_thread.h"
#include "../ngx_cp_custom_response.h"

ngx_int_t
ngx_http_cp_res_body_filter_async(ngx_http_request_t *request, ngx_chain_t *body_chain)
{
    ngx_http_cp_session_data *session_data_p;

    set_current_session_id(0);

    session_data_p = recover_cp_session_data(request);
    if (session_data_p == NULL) {
        write_dbg(DBG_LEVEL_DEBUG, "No session data - passing through to next filter");
        return ngx_http_next_response_body_filter(request, body_chain);
    }

    set_current_session_id(session_data_p->session_id);

    if (session_data_p->verdict != TRAFFIC_VERDICT_INSPECT) {
        write_dbg(DBG_LEVEL_TRACE, "Skipping already inspected session");
        if (session_data_p->verdict == TRAFFIC_VERDICT_DROP) {
            request->keepalive = 0;
        }

        if (session_data_p->verdict == TRAFFIC_VERDICT_DROP && session_data_p->is_res_body_inspected) {
            write_dbg(
                DBG_LEVEL_DEBUG,
                "Returning HTTP_FORBIDDEN for dropped session %d",
                session_data_p->session_id
            );
            return ngx_http_filter_finalize_request(request, &ngx_http_cp_attachment_module, NGX_HTTP_FORBIDDEN);
        }
        return ngx_http_next_response_body_filter(request, body_chain);
    }

    return ngx_http_cp_res_body_filter_core(request, body_chain, ASYNC_FILTER);
}

/* Resolve a transport/context failure before releasing any queued bytes. */
static ngx_int_t
cp_async_body_failure(ngx_http_request_t *r, ngx_http_cp_session_data *sd,
                      ngx_http_cp_async_ctx_t *ctx, ngx_chain_t *in)
{
    ngx_int_t rc = NGX_HTTP_FORBIDDEN;
    sd->verdict = fail_mode_verdict == NGX_OK ? TRAFFIC_VERDICT_ACCEPT : TRAFFIC_VERDICT_DROP;
    sd->async_processing_needed = 0;
    sd->remaining_messages_to_reply = 0;
    if (fail_mode_verdict == NGX_OK) {
        if (ctx && ctx->queue_head) {
            if (in && chain_add_copy(r, ctx, in) != NGX_OK) return NGX_ERROR;
            rc = ngx_http_next_request_body_filter(r, ctx->queue_head);
        } else {
            rc = ngx_http_next_request_body_filter(r, in);
        }
    }
    if (ctx) {
        queue_free(r, ctx);
        SAFE_DESTROY_CTX(ctx);
    }
    return rc;
}

ngx_int_t
ngx_http_cp_req_body_filter_async(ngx_http_request_t *r, ngx_chain_t *in)
{
    ngx_http_cp_session_data *sd = recover_cp_session_data(r);
    ngx_http_cp_async_ctx_t *ctx;

    if (!sd) return ngx_http_next_request_body_filter(r, in);
    /* The body reader flushes the filter chain each time it is resumed. Once the
     * queued body including its last buffer has reached the save filter, a second
     * empty flush would make it rewrite a file-backed body ("body already in file"). */
    if (in == NULL && r->request_body && r->request_body->last_saved) return NGX_OK;
    ctx = ngx_cp_async_find_ctx(sd->session_id);

    if (sd->verdict == TRAFFIC_VERDICT_DROP || sd->verdict == TRAFFIC_VERDICT_CUSTOM_RESPONSE) {
        ServiceVerdict verdict = sd->verdict;
        if (ctx) queue_free(r, ctx);
        SAFE_DESTROY_CTX(ctx);
        return verdict == TRAFFIC_VERDICT_CUSTOM_RESPONSE ?
            ngx_http_cp_finalize_custom_response_request(r) : NGX_HTTP_FORBIDDEN;
    }
    if (sd->verdict == TRAFFIC_VERDICT_ACCEPT || sd->verdict == TRAFFIC_VERDICT_IRRELEVANT) {
        ngx_int_t rc;
        if (ctx && ctx->queue_head) {
            if (in && chain_add_copy(r, ctx, in) != NGX_OK) return NGX_ERROR;
            rc = ngx_http_next_request_body_filter(r, ctx->queue_head);
            queue_free(r, ctx);
        } else {
            rc = ngx_http_next_request_body_filter(r, in);
        }
        SAFE_DESTROY_CTX(ctx);
        return rc;
    }

    if (sd->body_processed) {
        ngx_chain_t *cl;
        for (cl = in; cl; cl = cl->next) {
            if (cl->buf && ngx_buf_size(cl->buf) != 0) break;
        }
        if (cl == NULL) return ngx_http_next_request_body_filter(r, in);
    }

    if (!ctx || !ngx_cp_primary_ipc_ready() || !sd->initial_async_mode || ctx->flow_error ||
        !sd->async_processing_needed) {
        return cp_async_body_failure(r, sd, ctx, in);
    }

    if (!ctx->body_phase_started) {
        r->request_body->filter_need_buffering = 1;
        ctx->body_phase_started = 1;
    }

    /* Keep NGINX's original buffers busy until their verdict is available.
     * Return OK so NGINX can update its busy chains and chunk parser state;
     * filter_need_buffering makes the reader yield while these buffers are held.
     * This also covers chunked uploads whose final buffer has no body bytes. */
    if (in) {
        if (ctx->queue_head == NULL) ctx->queue_first_part_index = ctx->body_part_index;
        if (chain_add_copy(r, ctx, in) != NGX_OK) return NGX_ERROR;
        for (ngx_chain_t *cl = in; cl; cl = cl->next) {
            ngx_uint_t nmsgs = 0;
            ngx_buf_t *b = cl->buf;
            if (b == NULL) continue;
            if (ngx_cp_async_send_single_body_chunk_nonblocking(ctx, cl, &nmsgs) != NGX_OK) {
                return cp_async_body_failure(r, sd, ctx, NULL);
            }
            ctx->req_seq += nmsgs;
            sd->remaining_messages_to_reply += nmsgs;
            if (b->last_buf && !ctx->end_transaction_sent) {
                if (ngx_cp_async_send_end_transaction_nonblocking(ctx, &nmsgs) != NGX_OK) {
                    return cp_async_body_failure(r, sd, ctx, NULL);
                }
                ctx->req_seen_last = 1;
                ctx->req_seq += nmsgs;
                sd->remaining_messages_to_reply += nmsgs;
            }
        }
        ctx->waiting = 1;
        ngx_cp_async_start_deadline_timer(ctx, ngx_max(req_max_proccessing_ms_time, async_body_stage_timeout));
        if (ctx->req_seq == 0 && sd->verdict != TRAFFIC_VERDICT_DELAYED) {
            ngx_cp_async_event_handler(&ctx->agent_event);
        }
    }
    return ctx->queue_head || ctx->req_seq ? NGX_OK : ngx_http_next_request_body_filter(r, NULL);
}
