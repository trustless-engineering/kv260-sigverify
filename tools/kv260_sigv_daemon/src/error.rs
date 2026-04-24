use std::error::Error as StdError;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    Parse,
    InvalidRequest,
    Limit,
    Accelerator,
    Timeout,
    Unavailable,
}

impl ErrorKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Parse => "parse_error",
            Self::InvalidRequest => "invalid_request",
            Self::Limit => "limit_error",
            Self::Accelerator => "accelerator_error",
            Self::Timeout => "service_timeout",
            Self::Unavailable => "service_unavailable",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceError {
    pub kind: ErrorKind,
    pub code: String,
    pub message: String,
}

impl fmt::Display for ServiceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl StdError for ServiceError {}

impl ServiceError {
    fn new(kind: ErrorKind, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            kind,
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn parse(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Parse, code, message)
    }

    pub fn invalid_request(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::new(ErrorKind::InvalidRequest, code, message)
    }

    pub fn limit(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Limit, code, message)
    }

    pub fn accelerator(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Accelerator, code, message)
    }

    pub fn timeout(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Timeout, code, message)
    }

    pub fn unavailable(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unavailable, code, message)
    }
}
