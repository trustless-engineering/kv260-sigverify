use crate::accelerator::{
    error_code_name, AcceleratorStatus, HardwareBatchRequest, HardwareBatchResult,
    SigverifyAccelerator, VerificationJob, VerifyMode,
};
use crate::error::{ErrorKind, ServiceError};
use crate::parser;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    accelerator: Arc<dyn SigverifyAccelerator>,
}

#[derive(Debug, Deserialize)]
struct EncodedPayload {
    encoding: PayloadEncoding,
    data: String,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum PayloadEncoding {
    Base64,
    Hex,
}

#[derive(Debug, Deserialize)]
struct VerifyTransactionRequest {
    transaction: EncodedPayload,
    #[serde(default)]
    verify_mode: VerifyMode,
    #[serde(default = "default_timeout_ms")]
    timeout_ms: u64,
    #[serde(default)]
    dispatch_limit: u8,
    #[serde(default)]
    job_timeout_cycles: u32,
    #[serde(default)]
    include_parse_summary: bool,
}

fn default_timeout_ms() -> u64 {
    5_000
}

#[derive(Debug, Deserialize)]
struct BatchJobRequest {
    pubkey: String,
    signature: String,
}

#[derive(Debug, Deserialize)]
struct VerifyBatchRequest {
    message: EncodedPayload,
    jobs: Vec<BatchJobRequest>,
    #[serde(default)]
    verify_mode: VerifyMode,
    #[serde(default = "default_timeout_ms")]
    timeout_ms: u64,
    #[serde(default)]
    dispatch_limit: u8,
    #[serde(default)]
    job_timeout_cycles: u32,
}

#[derive(Debug, Serialize)]
struct VerifySuccessResponse {
    ok: bool,
    request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    parsed: Option<ParsedSummary>,
    verification: VerificationSummary,
    hardware: HardwareSummary,
}

#[derive(Debug, Serialize)]
struct ParsedSummary {
    message_version: String,
    message_length: usize,
    num_required_signatures: u8,
}

#[derive(Debug, Serialize)]
struct VerificationSummary {
    verify_mode: String,
    verified: bool,
    all_signers_verified: bool,
    result_bits: Vec<bool>,
    result_mask_hex: String,
}

#[derive(Debug, Serialize)]
struct HardwareSummary {
    batch_id: u32,
    accepted_job_count: u8,
    jobs_completed: u32,
    jobs_dropped: u32,
    error: bool,
    error_code: String,
    last_job_cycles: u32,
    last_batch_cycles: u32,
}

#[derive(Debug, Serialize)]
struct StatusResponse {
    ok: bool,
    ready: bool,
    fpga_loaded: bool,
    control_path: String,
    message_path: String,
    job_path: String,
    last_seen_batch_id: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hardware_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hardware_api_version: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

#[derive(Debug, Serialize)]
struct ErrorEnvelope {
    ok: bool,
    request_id: String,
    error: ErrorBody,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    #[serde(rename = "type")]
    error_type: String,
    code: String,
    message: String,
}

pub fn build_router(accelerator: Arc<dyn SigverifyAccelerator>) -> Router {
    Router::new()
        .route("/v1/status", get(get_status))
        .route("/v1/verify-transaction", post(post_verify_transaction))
        .route("/v1/verify-batch", post(post_verify_batch))
        .with_state(AppState { accelerator })
}

async fn get_status(State(state): State<AppState>) -> impl IntoResponse {
    let accelerator = state.accelerator.clone();
    let status = tokio::task::spawn_blocking(move || accelerator.status())
        .await
        .unwrap_or_else(|error| AcceleratorStatus {
            ready: false,
            fpga_loaded: false,
            control_path: "unknown".to_string(),
            message_path: "unknown".to_string(),
            job_path: "unknown".to_string(),
            last_seen_batch_id: None,
            hardware_mode: None,
            hardware_api_version: None,
            detail: Some(format!("status worker failed: {error}")),
        });

    Json(StatusResponse {
        ok: true,
        ready: status.ready,
        fpga_loaded: status.fpga_loaded,
        control_path: status.control_path,
        message_path: status.message_path,
        job_path: status.job_path,
        last_seen_batch_id: status.last_seen_batch_id,
        hardware_mode: status.hardware_mode,
        hardware_api_version: status.hardware_api_version,
        detail: status.detail,
    })
}

async fn post_verify_transaction(State(state): State<AppState>, body: Bytes) -> Response {
    let request_id = Uuid::new_v4().to_string();
    match parse_json::<VerifyTransactionRequest>(&body)
        .and_then(build_transaction_batch_request)
        .and_then(|request| validate_timeout_ms(request.timeout_ms).map(|()| request))
    {
        Ok(request) => match execute_verify(state.accelerator.clone(), request.batch_request).await
        {
            Ok(result) => success_response(
                request_id,
                request.parsed_summary,
                request.total_jobs,
                request.verify_mode,
                result,
            ),
            Err(error) => error_response(request_id, error),
        },
        Err(error) => error_response(request_id, error),
    }
}

async fn post_verify_batch(State(state): State<AppState>, body: Bytes) -> Response {
    let request_id = Uuid::new_v4().to_string();
    match parse_json::<VerifyBatchRequest>(&body)
        .and_then(build_logical_batch_request)
        .and_then(|request| validate_timeout_ms(request.timeout_ms).map(|()| request))
    {
        Ok(request) => match execute_verify(state.accelerator.clone(), request.batch_request).await
        {
            Ok(result) => success_response(
                request_id,
                None,
                request.total_jobs,
                request.verify_mode,
                result,
            ),
            Err(error) => error_response(request_id, error),
        },
        Err(error) => error_response(request_id, error),
    }
}

async fn execute_verify(
    accelerator: Arc<dyn SigverifyAccelerator>,
    batch_request: HardwareBatchRequest,
) -> Result<HardwareBatchResult, ServiceError> {
    tokio::task::spawn_blocking(move || accelerator.verify_batch(batch_request))
        .await
        .map_err(|error| {
            ServiceError::unavailable(
                "worker_join_failure",
                format!("accelerator worker failed: {error}"),
            )
        })?
}

fn success_response(
    request_id: String,
    parsed_summary: Option<ParsedSummary>,
    total_jobs: usize,
    verify_mode: VerifyMode,
    result: HardwareBatchResult,
) -> Response {
    let all_signers_verified = result.result_valid
        && !result.error
        && result.accepted_job_count as usize == total_jobs
        && result.jobs_dropped == 0
        && !result.result_bits.is_empty()
        && result.result_bits.iter().all(|bit| *bit);

    (
        StatusCode::OK,
        Json(VerifySuccessResponse {
            ok: true,
            request_id,
            parsed: parsed_summary,
            verification: VerificationSummary {
                verify_mode: verify_mode.as_str().to_string(),
                verified: all_signers_verified,
                all_signers_verified,
                result_bits: result.result_bits.clone(),
                result_mask_hex: result.result_mask_hex.clone(),
            },
            hardware: HardwareSummary {
                batch_id: result.batch_id,
                accepted_job_count: result.accepted_job_count,
                jobs_completed: result.jobs_completed,
                jobs_dropped: result.jobs_dropped,
                error: result.error,
                error_code: error_code_name(result.error_code),
                last_job_cycles: result.last_job_cycles,
                last_batch_cycles: result.last_batch_cycles,
            },
        }),
    )
        .into_response()
}

fn error_response(request_id: String, error: ServiceError) -> Response {
    (
        status_code_for_error(error.kind),
        Json(ErrorEnvelope {
            ok: false,
            request_id,
            error: ErrorBody {
                error_type: error.kind.as_str().to_string(),
                code: error.code,
                message: error.message,
            },
        }),
    )
        .into_response()
}

fn status_code_for_error(kind: ErrorKind) -> StatusCode {
    match kind {
        ErrorKind::Parse | ErrorKind::InvalidRequest => StatusCode::BAD_REQUEST,
        ErrorKind::Limit => StatusCode::UNPROCESSABLE_ENTITY,
        ErrorKind::Accelerator => StatusCode::UNPROCESSABLE_ENTITY,
        ErrorKind::Timeout => StatusCode::GATEWAY_TIMEOUT,
        ErrorKind::Unavailable => StatusCode::SERVICE_UNAVAILABLE,
    }
}

fn parse_json<T: DeserializeOwned>(body: &[u8]) -> Result<T, ServiceError> {
    serde_json::from_slice(body).map_err(|error| {
        ServiceError::invalid_request("invalid_json", format!("invalid JSON body: {error}"))
    })
}

fn validate_timeout_ms(timeout_ms: u64) -> Result<(), ServiceError> {
    if timeout_ms == 0 {
        return Err(ServiceError::invalid_request(
            "invalid_timeout",
            "timeout_ms must be greater than zero",
        ));
    }
    Ok(())
}

fn decode_payload(payload: &EncodedPayload, label: &str) -> Result<Vec<u8>, ServiceError> {
    match payload.encoding {
        PayloadEncoding::Base64 => STANDARD.decode(payload.data.trim()).map_err(|error| {
            ServiceError::parse("invalid_base64", format!("invalid base64 {label}: {error}"))
        }),
        PayloadEncoding::Hex => hex::decode(payload.data.trim()).map_err(|error| {
            ServiceError::parse("invalid_hex", format!("invalid hex {label}: {error}"))
        }),
    }
}

fn decode_fixed_base64<const N: usize>(value: &str, label: &str) -> Result<[u8; N], ServiceError> {
    let bytes = STANDARD.decode(value.trim()).map_err(|error| {
        ServiceError::parse("invalid_base64", format!("invalid base64 {label}: {error}"))
    })?;
    if bytes.len() != N {
        return Err(ServiceError::invalid_request(
            format!("invalid_{label}_length"),
            format!(
                "{label} must be exactly {N} bytes after base64 decode (got {})",
                bytes.len()
            ),
        ));
    }
    Ok(bytes.try_into().expect("slice length is checked"))
}

struct BuiltRequest {
    batch_request: HardwareBatchRequest,
    parsed_summary: Option<ParsedSummary>,
    verify_mode: VerifyMode,
    timeout_ms: u64,
    total_jobs: usize,
}

fn build_transaction_batch_request(
    request: VerifyTransactionRequest,
) -> Result<BuiltRequest, ServiceError> {
    let transaction_bytes = decode_payload(&request.transaction, "transaction")?;
    let parsed = parser::parse_transaction(&transaction_bytes)
        .map_err(|error| ServiceError::parse("transaction_parse_failed", error.to_string()))?;
    if parsed.jobs.is_empty() {
        return Err(ServiceError::parse(
            "empty_signer_set",
            "transaction did not produce any verification jobs",
        ));
    }

    let jobs = parsed
        .jobs
        .iter()
        .map(|job| VerificationJob {
            pubkey: job.pubkey,
            signature: job.signature,
        })
        .collect::<Vec<_>>();

    Ok(BuiltRequest {
        batch_request: HardwareBatchRequest {
            message: parsed.message_bytes.clone(),
            jobs,
            verify_mode: request.verify_mode,
            timeout: Duration::from_millis(request.timeout_ms),
            dispatch_limit: request.dispatch_limit,
            job_timeout_cycles: request.job_timeout_cycles,
        },
        parsed_summary: request.include_parse_summary.then(|| ParsedSummary {
            message_version: parsed.message_version.to_string(),
            message_length: parsed.message_bytes.len(),
            num_required_signatures: parsed.num_required_signatures,
        }),
        verify_mode: request.verify_mode,
        timeout_ms: request.timeout_ms,
        total_jobs: parsed.jobs.len(),
    })
}

fn build_logical_batch_request(request: VerifyBatchRequest) -> Result<BuiltRequest, ServiceError> {
    let message = decode_payload(&request.message, "message")?;
    if message.is_empty() {
        return Err(ServiceError::invalid_request(
            "empty_message",
            "message must contain the exact serialized Solana message bytes",
        ));
    }
    if request.jobs.is_empty() {
        return Err(ServiceError::invalid_request(
            "empty_jobs",
            "jobs must contain at least one pubkey/signature tuple",
        ));
    }

    let mut jobs = Vec::with_capacity(request.jobs.len());
    for (index, job) in request.jobs.iter().enumerate() {
        jobs.push(VerificationJob {
            pubkey: decode_fixed_base64::<32>(&job.pubkey, &format!("jobs[{index}].pubkey"))?,
            signature: decode_fixed_base64::<64>(
                &job.signature,
                &format!("jobs[{index}].signature"),
            )?,
        });
    }

    Ok(BuiltRequest {
        total_jobs: jobs.len(),
        batch_request: HardwareBatchRequest {
            message,
            jobs,
            verify_mode: request.verify_mode,
            timeout: Duration::from_millis(request.timeout_ms),
            dispatch_limit: request.dispatch_limit,
            job_timeout_cycles: request.job_timeout_cycles,
        },
        parsed_summary: None,
        verify_mode: request.verify_mode,
        timeout_ms: request.timeout_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::build_router;
    use crate::accelerator::{
        AcceleratorStatus, HardwareBatchRequest, HardwareBatchResult, SigverifyAccelerator,
        VerifyMode,
    };
    use crate::error::ServiceError;
    use crate::parser::encode_compact_u16;
    use axum::body::{to_bytes, Body};
    use axum::http::{Method, Request, StatusCode};
    use base64::Engine;
    use serde_json::{json, Value};
    use std::sync::{Arc, Mutex};
    use tower::ServiceExt;

    #[derive(Clone)]
    struct MockAccelerator {
        status: AcceleratorStatus,
        result: Arc<Mutex<Result<HardwareBatchResult, ServiceError>>>,
        last_request: Arc<Mutex<Option<HardwareBatchRequest>>>,
    }

    impl MockAccelerator {
        fn new(
            status: AcceleratorStatus,
            result: Result<HardwareBatchResult, ServiceError>,
        ) -> Self {
            Self {
                status,
                result: Arc::new(Mutex::new(result)),
                last_request: Arc::new(Mutex::new(None)),
            }
        }
    }

    impl SigverifyAccelerator for MockAccelerator {
        fn verify_batch(
            &self,
            request: HardwareBatchRequest,
        ) -> Result<HardwareBatchResult, ServiceError> {
            *self.last_request.lock().unwrap() = Some(request);
            self.result.lock().unwrap().clone()
        }

        fn status(&self) -> AcceleratorStatus {
            self.status.clone()
        }
    }

    fn build_legacy_transaction() -> (Vec<u8>, Vec<u8>, [u8; 32], [u8; 64]) {
        let signature = [0xa5; 64];
        let signer: [u8; 32] = (0..32).collect::<Vec<_>>().try_into().unwrap();
        let program: [u8; 32] = (32..64).collect::<Vec<_>>().try_into().unwrap();
        let blockhash = [0x11; 32];

        let mut message = Vec::new();
        message.extend_from_slice(&[0x01, 0x00, 0x01]);
        message.extend(encode_compact_u16(2));
        message.extend_from_slice(&signer);
        message.extend_from_slice(&program);
        message.extend_from_slice(&blockhash);
        message.extend(encode_compact_u16(1));
        message.push(0x01);
        message.extend(encode_compact_u16(1));
        message.push(0x00);
        message.extend(encode_compact_u16(2));
        message.extend_from_slice(&[0xca, 0xfe]);

        let mut transaction = Vec::new();
        transaction.extend(encode_compact_u16(1));
        transaction.extend_from_slice(&signature);
        transaction.extend_from_slice(&message);
        (transaction, message, signer, signature)
    }

    async fn read_json(response: axum::response::Response) -> Value {
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    fn status_template(ready: bool) -> AcceleratorStatus {
        AcceleratorStatus {
            ready,
            fpga_loaded: ready,
            control_path: "/dev/uio0".to_string(),
            message_path: "/dev/uio1".to_string(),
            job_path: "/dev/uio2".to_string(),
            last_seen_batch_id: Some(41),
            hardware_mode: Some("full".to_string()),
            hardware_api_version: Some(1),
            detail: (!ready).then(|| "hardware unavailable".to_string()),
        }
    }

    fn success_result() -> HardwareBatchResult {
        HardwareBatchResult {
            batch_id: 42,
            accepted_job_count: 1,
            jobs_completed: 1,
            jobs_dropped: 0,
            error: false,
            result_valid: true,
            error_code: 0,
            result_mask_hex: "0000000000000000000000000000000000000000000000000000000000000001"
                .to_string(),
            result_bits: vec![true],
            last_job_cycles: 812345,
            last_batch_cycles: 812345,
        }
    }

    #[tokio::test]
    async fn verify_transaction_returns_expected_json() {
        let mock = MockAccelerator::new(status_template(true), Ok(success_result()));
        let last_request = mock.last_request.clone();
        let app = build_router(Arc::new(mock));
        let (transaction, message, signer, signature) = build_legacy_transaction();

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/v1/verify-transaction")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "transaction": {
                                "encoding": "base64",
                                "data": base64::engine::general_purpose::STANDARD.encode(transaction),
                            },
                            "verify_mode": "strict",
                            "include_parse_summary": true
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let payload = read_json(response).await;
        assert_eq!(payload["ok"], true);
        assert_eq!(payload["parsed"]["message_version"], "legacy");
        assert_eq!(payload["parsed"]["message_length"], message.len());
        assert_eq!(payload["verification"]["verified"], true);
        assert_eq!(payload["hardware"]["batch_id"], 42);

        let captured = last_request.lock().unwrap().clone().unwrap();
        assert_eq!(captured.verify_mode, VerifyMode::Strict);
        assert_eq!(captured.message, message);
        assert_eq!(captured.jobs.len(), 1);
        assert_eq!(captured.jobs[0].pubkey, signer);
        assert_eq!(captured.jobs[0].signature, signature);
    }

    #[tokio::test]
    async fn verify_batch_rejects_invalid_job_length() {
        let mock = MockAccelerator::new(status_template(true), Ok(success_result()));
        let app = build_router(Arc::new(mock));

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/v1/verify-batch")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "message": {
                                "encoding": "base64",
                                "data": base64::engine::general_purpose::STANDARD.encode([0x01, 0x02, 0x03]),
                            },
                            "jobs": [{
                                "pubkey": base64::engine::general_purpose::STANDARD.encode([0u8; 31]),
                                "signature": base64::engine::general_purpose::STANDARD.encode([0u8; 64]),
                            }]
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let payload = read_json(response).await;
        assert_eq!(payload["ok"], false);
        assert_eq!(payload["error"]["type"], "invalid_request");
        assert_eq!(payload["error"]["code"], "invalid_jobs[0].pubkey_length");
    }

    #[tokio::test]
    async fn verify_batch_surfaces_accelerator_busy_as_service_unavailable() {
        let mock = MockAccelerator::new(
            status_template(true),
            Err(ServiceError::unavailable(
                "accelerator_busy",
                "another verification request is already running",
            )),
        );
        let app = build_router(Arc::new(mock));

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/v1/verify-batch")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "message": {
                                "encoding": "base64",
                                "data": base64::engine::general_purpose::STANDARD.encode([0x01, 0x02, 0x03]),
                            },
                            "jobs": [{
                                "pubkey": base64::engine::general_purpose::STANDARD.encode([0u8; 32]),
                                "signature": base64::engine::general_purpose::STANDARD.encode([0u8; 64]),
                            }]
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let payload = read_json(response).await;
        assert_eq!(payload["ok"], false);
        assert_eq!(payload["error"]["type"], "service_unavailable");
        assert_eq!(payload["error"]["code"], "accelerator_busy");
    }

    #[tokio::test]
    async fn verify_transaction_reports_parse_errors() {
        let mock = MockAccelerator::new(status_template(true), Ok(success_result()));
        let app = build_router(Arc::new(mock));

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/v1/verify-transaction")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "transaction": {
                                "encoding": "base64",
                                "data": base64::engine::general_purpose::STANDARD.encode([0x01u8, 0x02, 0x03]),
                            }
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let payload = read_json(response).await;
        assert_eq!(payload["error"]["type"], "parse_error");
        assert_eq!(payload["error"]["code"], "transaction_parse_failed");
    }

    #[tokio::test]
    async fn status_reports_hardware_health() {
        let mock = MockAccelerator::new(status_template(false), Ok(success_result()));
        let app = build_router(Arc::new(mock));

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/v1/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let payload = read_json(response).await;
        assert_eq!(payload["ok"], true);
        assert_eq!(payload["ready"], false);
        assert_eq!(payload["detail"], "hardware unavailable");
    }
}
