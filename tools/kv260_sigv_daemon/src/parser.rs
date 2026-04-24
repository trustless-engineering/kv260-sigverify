use serde::Serialize;
use std::fmt;
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageVersion {
    Legacy,
    #[serde(rename = "v0")]
    V0,
}

impl fmt::Display for MessageVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Legacy => f.write_str("legacy"),
            Self::V0 => f.write_str("v0"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerificationJob {
    pub index: usize,
    pub pubkey: [u8; 32],
    pub signature: [u8; 64],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTransaction {
    pub transaction_bytes: Vec<u8>,
    pub message_bytes: Vec<u8>,
    pub message_version: MessageVersion,
    pub num_required_signatures: u8,
    pub jobs: Vec<VerificationJob>,
}

#[derive(Debug, Clone, Error, PartialEq, Eq)]
#[error("{message}")]
pub struct ParseError {
    message: String,
}

impl ParseError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone)]
struct ParsedMessage {
    message_version: MessageVersion,
    num_required_signatures: u8,
    static_account_keys: Vec<[u8; 32]>,
}

pub fn encode_compact_u16(value: u16) -> Vec<u8> {
    let mut encoded = Vec::new();
    let mut remaining = value;
    loop {
        let byte = (remaining & 0x7f) as u8;
        remaining >>= 7;
        if remaining != 0 {
            encoded.push(byte | 0x80);
        } else {
            encoded.push(byte);
            break;
        }
    }
    encoded
}

pub fn decode_compact_u16(data: &[u8], mut offset: usize) -> Result<(u16, usize), ParseError> {
    let mut value: u32 = 0;
    let mut shift = 0;
    for _ in 0..3 {
        let byte = *data
            .get(offset)
            .ok_or_else(|| ParseError::new("truncated compact-u16"))?;
        offset += 1;
        value |= ((byte & 0x7f) as u32) << shift;
        if byte & 0x80 == 0 {
            if value > u16::MAX as u32 {
                return Err(ParseError::new("compact-u16 overflow"));
            }
            return Ok((value as u16, offset));
        }
        shift += 7;
    }
    Err(ParseError::new("compact-u16 exceeds 3 bytes"))
}

fn take<'a>(
    data: &'a [u8],
    offset: usize,
    size: usize,
    label: &str,
) -> Result<(&'a [u8], usize), ParseError> {
    let end = offset.saturating_add(size);
    if end > data.len() {
        return Err(ParseError::new(format!("truncated {label}")));
    }
    Ok((&data[offset..end], end))
}

fn skip_compiled_instructions(data: &[u8], mut offset: usize) -> Result<usize, ParseError> {
    let (instruction_count, next_offset) = decode_compact_u16(data, offset)?;
    offset = next_offset;
    for _ in 0..instruction_count {
        let (_, next_offset) = take(data, offset, 1, "program_id_index")?;
        offset = next_offset;
        let (account_index_count, next_offset) = decode_compact_u16(data, offset)?;
        offset = next_offset;
        let (_, next_offset) = take(
            data,
            offset,
            account_index_count as usize,
            "instruction account indices",
        )?;
        offset = next_offset;
        let (data_length, next_offset) = decode_compact_u16(data, offset)?;
        offset = next_offset;
        let (_, next_offset) = take(data, offset, data_length as usize, "instruction data")?;
        offset = next_offset;
    }
    Ok(offset)
}

fn skip_address_table_lookups(data: &[u8], mut offset: usize) -> Result<usize, ParseError> {
    let (lookup_count, next_offset) = decode_compact_u16(data, offset)?;
    offset = next_offset;
    for _ in 0..lookup_count {
        let (_, next_offset) = take(data, offset, 32, "lookup account key")?;
        offset = next_offset;
        let (writable_count, next_offset) = decode_compact_u16(data, offset)?;
        offset = next_offset;
        let (_, next_offset) = take(
            data,
            offset,
            writable_count as usize,
            "writable lookup indices",
        )?;
        offset = next_offset;
        let (readonly_count, next_offset) = decode_compact_u16(data, offset)?;
        offset = next_offset;
        let (_, next_offset) = take(
            data,
            offset,
            readonly_count as usize,
            "readonly lookup indices",
        )?;
        offset = next_offset;
    }
    Ok(offset)
}

fn parse_message(message_bytes: &[u8]) -> Result<ParsedMessage, ParseError> {
    if message_bytes.is_empty() {
        return Err(ParseError::new("transaction is missing message bytes"));
    }

    let (message_version, header_offset) = if message_bytes[0] & 0x80 != 0 {
        let version = message_bytes[0] & 0x7f;
        if version != 0 {
            return Err(ParseError::new(format!(
                "unsupported message version: {version}"
            )));
        }
        (MessageVersion::V0, 1)
    } else {
        (MessageVersion::Legacy, 0)
    };

    if header_offset + 3 > message_bytes.len() {
        return Err(ParseError::new("truncated message header"));
    }

    let num_required_signatures = message_bytes[header_offset];
    let mut offset = header_offset + 3;

    let (account_key_count, next_offset) = decode_compact_u16(message_bytes, offset)?;
    offset = next_offset;
    let mut static_account_keys = Vec::with_capacity(account_key_count as usize);
    for _ in 0..account_key_count {
        let (account_key, next_offset) = take(message_bytes, offset, 32, "account key")?;
        offset = next_offset;
        static_account_keys.push(account_key.try_into().expect("account keys are 32 bytes"));
    }

    let (_, next_offset) = take(message_bytes, offset, 32, "recent blockhash")?;
    offset = next_offset;
    offset = skip_compiled_instructions(message_bytes, offset)?;

    if message_version == MessageVersion::V0 {
        offset = skip_address_table_lookups(message_bytes, offset)?;
    }

    if offset != message_bytes.len() {
        return Err(ParseError::new("trailing bytes remain after message parse"));
    }

    Ok(ParsedMessage {
        message_version,
        num_required_signatures,
        static_account_keys,
    })
}

pub fn parse_transaction(transaction_bytes: &[u8]) -> Result<ParsedTransaction, ParseError> {
    let (num_signatures, mut offset) = decode_compact_u16(transaction_bytes, 0)?;

    let mut signatures = Vec::with_capacity(num_signatures as usize);
    for _ in 0..num_signatures {
        let (signature, next_offset) = take(transaction_bytes, offset, 64, "signature")?;
        offset = next_offset;
        signatures.push(signature.try_into().expect("signatures are 64 bytes"));
    }

    let message_bytes = transaction_bytes[offset..].to_vec();
    let message_info = parse_message(&message_bytes)?;

    if num_signatures as u8 != message_info.num_required_signatures {
        return Err(ParseError::new(format!(
            "signature count does not match message header ({} != {})",
            num_signatures, message_info.num_required_signatures
        )));
    }

    if message_info.static_account_keys.len() < message_info.num_required_signatures as usize {
        return Err(ParseError::new(
            "not enough static account keys for signer set",
        ));
    }

    let jobs = signatures
        .into_iter()
        .enumerate()
        .map(|(index, signature)| VerificationJob {
            index,
            pubkey: message_info.static_account_keys[index],
            signature,
        })
        .collect();

    Ok(ParsedTransaction {
        transaction_bytes: transaction_bytes.to_vec(),
        message_bytes,
        message_version: message_info.message_version,
        num_required_signatures: message_info.num_required_signatures,
        jobs,
    })
}

#[cfg(test)]
mod tests {
    use super::{encode_compact_u16, parse_transaction, MessageVersion};

    fn shortvec(value: u16) -> Vec<u8> {
        encode_compact_u16(value)
    }

    fn build_legacy_transaction() -> (Vec<u8>, Vec<u8>, [u8; 32], [u8; 64]) {
        let signature = [0xa5; 64];
        let signer: [u8; 32] = (0..32).collect::<Vec<_>>().try_into().unwrap();
        let program: [u8; 32] = (32..64).collect::<Vec<_>>().try_into().unwrap();
        let blockhash = [0x11; 32];

        let mut message = Vec::new();
        message.extend_from_slice(&[0x01, 0x00, 0x01]);
        message.extend(shortvec(2));
        message.extend_from_slice(&signer);
        message.extend_from_slice(&program);
        message.extend_from_slice(&blockhash);
        message.extend(shortvec(1));
        message.push(0x01);
        message.extend(shortvec(1));
        message.push(0x00);
        message.extend(shortvec(2));
        message.extend_from_slice(&[0xca, 0xfe]);

        let mut transaction = Vec::new();
        transaction.extend(shortvec(1));
        transaction.extend_from_slice(&signature);
        transaction.extend_from_slice(&message);
        (transaction, message, signer, signature)
    }

    fn build_v0_transaction() -> (Vec<u8>, Vec<u8>, [u8; 32], [u8; 64]) {
        let signature = [0x5a; 64];
        let signer: [u8; 32] = (64..96).collect::<Vec<_>>().try_into().unwrap();
        let writable: [u8; 32] = (96..128).collect::<Vec<_>>().try_into().unwrap();
        let blockhash = [0x22; 32];

        let mut message = Vec::new();
        message.push(0x80);
        message.extend_from_slice(&[0x01, 0x00, 0x00]);
        message.extend(shortvec(2));
        message.extend_from_slice(&signer);
        message.extend_from_slice(&writable);
        message.extend_from_slice(&blockhash);
        message.extend(shortvec(0));
        message.extend(shortvec(0));

        let mut transaction = Vec::new();
        transaction.extend(shortvec(1));
        transaction.extend_from_slice(&signature);
        transaction.extend_from_slice(&message);
        (transaction, message, signer, signature)
    }

    #[test]
    fn extracts_legacy_verification_job() {
        let (transaction, message, signer, signature) = build_legacy_transaction();
        let parsed = parse_transaction(&transaction).unwrap();

        assert_eq!(parsed.message_version, MessageVersion::Legacy);
        assert_eq!(parsed.message_bytes, message);
        assert_eq!(parsed.num_required_signatures, 1);
        assert_eq!(parsed.jobs.len(), 1);
        assert_eq!(parsed.jobs[0].pubkey, signer);
        assert_eq!(parsed.jobs[0].signature, signature);
    }

    #[test]
    fn extracts_v0_verification_job() {
        let (transaction, message, signer, signature) = build_v0_transaction();
        let parsed = parse_transaction(&transaction).unwrap();

        assert_eq!(parsed.message_version, MessageVersion::V0);
        assert_eq!(parsed.message_bytes, message);
        assert_eq!(parsed.num_required_signatures, 1);
        assert_eq!(parsed.jobs.len(), 1);
        assert_eq!(parsed.jobs[0].pubkey, signer);
        assert_eq!(parsed.jobs[0].signature, signature);
    }

    #[test]
    fn rejects_signature_count_mismatch() {
        let (transaction, _, _, _) = build_legacy_transaction();
        let mut tampered = transaction;
        let message_offset = 1 + 64;
        tampered[message_offset] = 2;

        let error = parse_transaction(&tampered).unwrap_err();
        assert!(error.to_string().contains("signature count does not match"));
    }
}
