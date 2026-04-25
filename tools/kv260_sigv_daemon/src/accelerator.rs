use crate::error::ServiceError;
use clap::ValueEnum;
use memmap2::{MmapMut, MmapOptions};
use nix::poll::{poll, PollFd, PollFlags};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::mem::align_of;
use std::os::fd::AsFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

pub const CONTROL_BASE: u64 = 0xA000_0000;
pub const MESSAGE_BASE: u64 = 0xA001_0000;
pub const JOB_BASE: u64 = 0xA002_0000;

const CONTROL_SIZE: usize = 0x1000;
const MESSAGE_SIZE: usize = 0x1000;
const JOB_SIZE: usize = 0x8000;
const MAX_JOB_COUNT: usize = 255;

const REG_CONTROL: usize = 0x0000;
const REG_STATUS: usize = 0x0004;
const REG_MESSAGE_LEN: usize = 0x0008;
const REG_JOB_COUNT: usize = 0x000c;
const REG_RESULT_MASK_BASE: usize = 0x0010;
const REG_VERIFY_CFG: usize = 0x0038;
const REG_LAST_JOB_CYCLES: usize = 0x0050;
const REG_LAST_BATCH_CYCLES: usize = 0x0058;
const REG_JOB_TIMEOUT_CYCLES: usize = 0x005c;
const REG_IRQ_CTRL_STATUS: usize = 0x0060;
const REG_BATCH_ID: usize = 0x0064;
const REG_SNAPSHOT_BATCH_ID: usize = 0x0068;
const REG_SNAPSHOT_ACCEPTED: usize = 0x006c;
const REG_SNAPSHOT_COMPLETED: usize = 0x0070;
const REG_SNAPSHOT_DROPPED: usize = 0x0074;
const REG_SNAPSHOT_ERR_STATUS: usize = 0x0078;
const REG_HW_MAGIC: usize = 0x007c;
const REG_HW_BUILD: usize = 0x0080;

const HW_MAGIC: u32 = 0x5349_4756;
const HW_MODE_FULL: u8 = 0;
const HW_MODE_BRINGUP: u8 = 1;
const HW_API_VERSION: u8 = 1;

const CONTROL_CMD_START: u32 = 0x1;
const CONTROL_CMD_SOFT_RESET: u32 = 0x2;
const CONTROL_CMD_RESET_THEN_START: u32 = CONTROL_CMD_START | CONTROL_CMD_SOFT_RESET;
const IRQ_CTRL_ENABLE_AND_ACK: u32 = 0x3;
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(10);

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum VerifyMode {
    #[default]
    Strict,
    #[serde(alias = "agave")]
    AgaveZebra,
}

impl VerifyMode {
    pub fn register_bits(self) -> u32 {
        match self {
            Self::Strict => 0,
            Self::AgaveZebra => 1,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Strict => "strict",
            Self::AgaveZebra => "agave_zebra",
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum WaitMode {
    Auto,
    Irq,
    #[default]
    Poll,
}

#[derive(Debug, Clone)]
pub struct AcceleratorConfig {
    pub control_path: String,
    pub message_path: String,
    pub job_path: String,
    pub control_offset: u64,
    pub message_offset: u64,
    pub job_offset: u64,
    pub wait_mode: WaitMode,
}

impl Default for AcceleratorConfig {
    fn default() -> Self {
        Self {
            control_path: "auto".to_string(),
            message_path: "auto".to_string(),
            job_path: "auto".to_string(),
            control_offset: CONTROL_BASE,
            message_offset: MESSAGE_BASE,
            job_offset: JOB_BASE,
            wait_mode: WaitMode::Auto,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerificationJob {
    pub pubkey: [u8; 32],
    pub signature: [u8; 64],
}

#[derive(Debug, Clone)]
pub struct HardwareBatchRequest {
    pub message: Vec<u8>,
    pub jobs: Vec<VerificationJob>,
    pub verify_mode: VerifyMode,
    pub timeout: Duration,
    pub dispatch_limit: u8,
    pub job_timeout_cycles: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct AcceleratorStatus {
    pub ready: bool,
    pub fpga_loaded: bool,
    pub control_path: String,
    pub message_path: String,
    pub job_path: String,
    pub last_seen_batch_id: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hardware_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hardware_api_version: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone)]
pub struct HardwareBatchResult {
    pub batch_id: u32,
    pub accepted_job_count: u8,
    pub jobs_completed: u32,
    pub jobs_dropped: u32,
    pub error: bool,
    pub result_valid: bool,
    pub error_code: u8,
    pub result_mask_hex: String,
    pub result_bits: Vec<bool>,
    pub last_job_cycles: u32,
    pub last_batch_cycles: u32,
}

pub trait SigverifyAccelerator: Send + Sync + 'static {
    fn verify_batch(
        &self,
        request: HardwareBatchRequest,
    ) -> Result<HardwareBatchResult, ServiceError>;
    fn status(&self) -> AcceleratorStatus;
}

#[derive(Debug)]
pub struct MappedAccelerator {
    config: AcceleratorConfig,
}

pub struct SingleFlightAccelerator<A> {
    inner: A,
    busy: AtomicBool,
}

#[derive(Debug, Clone)]
struct RegionSpec {
    path: PathBuf,
    offset: u64,
    size: usize,
}

#[derive(Debug, Clone)]
struct HardwareLayout {
    control: RegionSpec,
    message: RegionSpec,
    job: RegionSpec,
}

#[derive(Debug)]
struct MappedRegion {
    _file: File,
    mapping: MmapMut,
    delta: usize,
    size: usize,
}

#[derive(Debug)]
struct UioInterrupt {
    file: File,
}

#[derive(Debug, Clone, Copy)]
struct StatusBits {
    done: bool,
    error: bool,
}

#[derive(Debug, Clone, Copy)]
struct SnapshotStatus {
    batch_id: u32,
    accepted_job_count: u8,
    jobs_completed: u32,
    jobs_dropped: u32,
    error: bool,
    result_valid: bool,
    error_code: u8,
}

#[derive(Debug, Clone, Copy)]
struct HardwareIdentity {
    mode: u8,
    api_version: u8,
}

struct BusyGuard<'a> {
    flag: &'a AtomicBool,
}

impl MappedAccelerator {
    pub fn new(config: AcceleratorConfig) -> Self {
        Self { config }
    }

    fn resolve_layout(&self) -> Result<HardwareLayout, ServiceError> {
        Ok(HardwareLayout {
            control: self.resolve_region(
                &self.config.control_path,
                self.config.control_offset,
                CONTROL_SIZE,
            )?,
            message: self.resolve_region(
                &self.config.message_path,
                self.config.message_offset,
                MESSAGE_SIZE,
            )?,
            job: self.resolve_region(&self.config.job_path, self.config.job_offset, JOB_SIZE)?,
        })
    }

    fn resolve_region(
        &self,
        path_value: &str,
        offset: u64,
        size: usize,
    ) -> Result<RegionSpec, ServiceError> {
        if path_value != "auto" {
            let path = PathBuf::from(path_value);
            let effective_offset = if path_uses_uio(&path) { 0 } else { offset };
            return Ok(RegionSpec {
                path,
                offset: effective_offset,
                size,
            });
        }

        if let Some(spec) = discover_uio_region(offset, size)? {
            return Ok(spec);
        }

        Ok(RegionSpec {
            path: PathBuf::from("/dev/mem"),
            offset,
            size,
        })
    }
}

impl<A> SingleFlightAccelerator<A> {
    pub fn new(inner: A) -> Self {
        Self {
            inner,
            busy: AtomicBool::new(false),
        }
    }
}

impl<'a> BusyGuard<'a> {
    fn try_acquire(flag: &'a AtomicBool) -> Result<Self, ServiceError> {
        flag.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| {
                ServiceError::unavailable(
                    "accelerator_busy",
                    "another verification request is already running",
                )
            })?;
        Ok(Self { flag })
    }
}

impl Drop for BusyGuard<'_> {
    fn drop(&mut self) {
        self.flag.store(false, Ordering::Release);
    }
}

impl<A> SigverifyAccelerator for SingleFlightAccelerator<A>
where
    A: SigverifyAccelerator,
{
    fn verify_batch(
        &self,
        request: HardwareBatchRequest,
    ) -> Result<HardwareBatchResult, ServiceError> {
        let _guard = BusyGuard::try_acquire(&self.busy)?;
        self.inner.verify_batch(request)
    }

    fn status(&self) -> AcceleratorStatus {
        self.inner.status()
    }
}

impl SigverifyAccelerator for MappedAccelerator {
    fn verify_batch(
        &self,
        request: HardwareBatchRequest,
    ) -> Result<HardwareBatchResult, ServiceError> {
        if request.message.is_empty() {
            return Err(ServiceError::invalid_request(
                "empty_message",
                "message must contain the exact serialized Solana message bytes",
            ));
        }
        if request.jobs.is_empty() {
            return Err(ServiceError::invalid_request(
                "empty_jobs",
                "batch must contain at least one verification job",
            ));
        }
        if request.message.len() > MESSAGE_SIZE {
            return Err(ServiceError::limit(
                "message_too_large",
                format!(
                    "message is too large for the mapped BRAM window ({} > {})",
                    request.message.len(),
                    MESSAGE_SIZE
                ),
            ));
        }
        if request.jobs.len() > MAX_JOB_COUNT {
            return Err(ServiceError::limit(
                "too_many_jobs",
                format!(
                    "job count exceeds the accelerator limit ({} > {})",
                    request.jobs.len(),
                    MAX_JOB_COUNT
                ),
            ));
        }

        let layout = self.resolve_layout()?;
        let wait_mode = wait_mode_for_layout(self.config.wait_mode, &layout.control.path)?;

        let mut jobs_bytes = Vec::with_capacity(request.jobs.len() * 96);
        for job in &request.jobs {
            jobs_bytes.extend_from_slice(&job.pubkey);
            jobs_bytes.extend_from_slice(&job.signature);
        }
        if jobs_bytes.len() > JOB_SIZE {
            return Err(ServiceError::limit(
                "jobs_too_large",
                format!(
                    "jobs payload is too large for the mapped BRAM window ({} > {})",
                    jobs_bytes.len(),
                    JOB_SIZE
                ),
            ));
        }

        let mut control = MappedRegion::open(&layout.control)?;
        let identity = probe_hardware_identity(&control)?;
        require_full_hardware(identity)?;
        let mut message_region = MappedRegion::open(&layout.message)?;
        let mut job_region = MappedRegion::open(&layout.job)?;

        message_region.write_bytes(&request.message)?;
        job_region.write_bytes(&jobs_bytes)?;
        control.write_u32(REG_MESSAGE_LEN, request.message.len() as u32)?;
        control.write_u32(REG_JOB_COUNT, request.jobs.len() as u32)?;
        control.write_u32(
            REG_VERIFY_CFG,
            ((request.dispatch_limit as u32) << 8) | request.verify_mode.register_bits(),
        )?;
        control.write_u32(REG_JOB_TIMEOUT_CYCLES, request.job_timeout_cycles)?;

        let expected_batch_id = control.read_u32(REG_BATCH_ID)?.wrapping_add(1);
        let deadline = Instant::now() + request.timeout;

        let status_word = match wait_mode {
            WaitMode::Irq => {
                let mut interrupt = UioInterrupt::open(&layout.control.path)?;
                control.write_u32(REG_IRQ_CTRL_STATUS, IRQ_CTRL_ENABLE_AND_ACK)?;
                interrupt.arm()?;
                control.write_u32(REG_CONTROL, CONTROL_CMD_RESET_THEN_START)?;
                interrupt.wait(request.timeout)?;
                control.write_u32(REG_IRQ_CTRL_STATUS, IRQ_CTRL_ENABLE_AND_ACK)?;

                let status_word = control.read_u32(REG_STATUS)?;
                let status = decode_status(status_word);
                if status.done || status.error {
                    status_word
                } else {
                    poll_until_complete(&control, deadline)?
                }
            }
            WaitMode::Poll | WaitMode::Auto => {
                control.write_u32(REG_CONTROL, CONTROL_CMD_RESET_THEN_START)?;
                poll_until_complete(&control, deadline)?
            }
        };

        let status = decode_status(status_word);
        if !(status.done || status.error) {
            return Err(ServiceError::timeout(
                "completion_not_visible",
                "accelerator did not expose a terminal completion state before timeout",
            ));
        }

        let snapshot = read_snapshot(&control)?;
        if snapshot.batch_id != expected_batch_id {
            return Err(ServiceError::unavailable(
                "snapshot_batch_id_mismatch",
                format!(
                    "snapshot batch_id mismatch: expected {expected_batch_id}, got {}",
                    snapshot.batch_id
                ),
            ));
        }

        let mask_words = read_result_mask(&control)?;
        let result_mask_hex = result_mask_hex(&mask_words);
        let result_bits = mask_bits(&mask_words, snapshot.accepted_job_count as usize);

        Ok(HardwareBatchResult {
            batch_id: snapshot.batch_id,
            accepted_job_count: snapshot.accepted_job_count,
            jobs_completed: snapshot.jobs_completed,
            jobs_dropped: snapshot.jobs_dropped,
            error: snapshot.error,
            result_valid: snapshot.result_valid,
            error_code: snapshot.error_code,
            result_mask_hex,
            result_bits,
            last_job_cycles: control.read_u32(REG_LAST_JOB_CYCLES)?,
            last_batch_cycles: control.read_u32(REG_LAST_BATCH_CYCLES)?,
        })
    }

    fn status(&self) -> AcceleratorStatus {
        let fallback = AcceleratorStatus {
            ready: false,
            fpga_loaded: false,
            control_path: self.config.control_path.clone(),
            message_path: self.config.message_path.clone(),
            job_path: self.config.job_path.clone(),
            last_seen_batch_id: None,
            hardware_mode: None,
            hardware_api_version: None,
            detail: None,
        };

        let layout = match self.resolve_layout() {
            Ok(layout) => layout,
            Err(error) => {
                return AcceleratorStatus {
                    detail: Some(error.message),
                    ..fallback
                }
            }
        };

        let control_path = layout.control.path.display().to_string();
        let message_path = layout.message.path.display().to_string();
        let job_path = layout.job.path.display().to_string();

        match MappedRegion::open(&layout.control).and_then(|control| {
            let identity = probe_hardware_identity(&control)?;
            let batch_id = control.read_u32(REG_BATCH_ID)?;
            Ok((identity, batch_id))
        }) {
            Ok((identity, batch_id)) => {
                let full_ready =
                    identity.mode == HW_MODE_FULL && identity.api_version == HW_API_VERSION;
                AcceleratorStatus {
                    ready: full_ready,
                    fpga_loaded: true,
                    control_path,
                    message_path,
                    job_path,
                    last_seen_batch_id: Some(batch_id),
                    hardware_mode: Some(hw_mode_name(identity.mode).to_string()),
                    hardware_api_version: Some(identity.api_version),
                    detail: if full_ready {
                        None
                    } else {
                        Some(format!(
                            "loaded hardware mode/api is {}/{}; expected full/{}",
                            hw_mode_name(identity.mode),
                            identity.api_version,
                            HW_API_VERSION
                        ))
                    },
                }
            }
            Err(error) => AcceleratorStatus {
                ready: false,
                fpga_loaded: false,
                control_path,
                message_path,
                job_path,
                last_seen_batch_id: None,
                hardware_mode: None,
                hardware_api_version: None,
                detail: Some(error.message),
            },
        }
    }
}

impl MappedRegion {
    fn open(spec: &RegionSpec) -> Result<Self, ServiceError> {
        let page_size = system_page_size()?;
        let aligned_offset = spec.offset - (spec.offset % page_size);
        let delta = (spec.offset - aligned_offset) as usize;

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_SYNC)
            .open(&spec.path)
            .map_err(|error| {
                ServiceError::unavailable(
                    "open_region_failed",
                    format!("failed to open {}: {error}", spec.path.display()),
                )
            })?;

        let mapping = unsafe {
            MmapOptions::new()
                .offset(aligned_offset)
                .len(delta + spec.size)
                .map_mut(&file)
        }
        .map_err(|error| {
            ServiceError::unavailable(
                "map_region_failed",
                format!("failed to map {}: {error}", spec.path.display()),
            )
        })?;

        Ok(Self {
            _file: file,
            mapping,
            delta,
            size: spec.size,
        })
    }

    fn read_u32(&self, offset: usize) -> Result<u32, ServiceError> {
        let start = self.checked_word_start(offset, "read")?;
        let value = unsafe {
            let word_ptr = self.mapping.as_ptr().add(start).cast::<u32>();
            ptr::read_volatile(word_ptr)
        };
        Ok(u32::from_le(value))
    }

    fn write_u32(&mut self, offset: usize, value: u32) -> Result<(), ServiceError> {
        let start = self.checked_word_start(offset, "write")?;
        unsafe {
            let word_ptr = self.mapping.as_mut_ptr().add(start).cast::<u32>();
            ptr::write_volatile(word_ptr, value.to_le());
        }
        Ok(())
    }

    fn write_bytes(&mut self, data: &[u8]) -> Result<(), ServiceError> {
        write_bytes_as_u32_words(data, self.size, |offset, value| {
            self.write_u32(offset, value)
        })
    }

    fn checked_word_start(&self, offset: usize, operation: &str) -> Result<usize, ServiceError> {
        let end = offset.checked_add(4).ok_or_else(|| {
            ServiceError::unavailable(
                "mmio_bounds",
                format!(
                    "attempted to {operation} past mapped region bounds at offset 0x{offset:04x}"
                ),
            )
        })?;
        if end > self.size {
            return Err(ServiceError::unavailable(
                "mmio_bounds",
                format!(
                    "attempted to {operation} past mapped region bounds at offset 0x{offset:04x}"
                ),
            ));
        }

        let start = self.delta.checked_add(offset).ok_or_else(|| {
            ServiceError::unavailable(
                "mmio_bounds",
                format!("attempted to {operation} using an overflowing MMIO offset 0x{offset:04x}"),
            )
        })?;
        if start % align_of::<u32>() != 0 {
            return Err(ServiceError::unavailable(
                "mmio_alignment",
                format!("attempted to {operation} unaligned MMIO word at offset 0x{offset:04x}"),
            ));
        }

        Ok(start)
    }
}

fn write_bytes_as_u32_words<F>(
    data: &[u8],
    region_size: usize,
    mut write_word: F,
) -> Result<(), ServiceError>
where
    F: FnMut(usize, u32) -> Result<(), ServiceError>,
{
    if data.len() > region_size {
        return Err(ServiceError::limit(
            "payload_too_large",
            format!(
                "payload is too large for the mapped region ({} > {})",
                data.len(),
                region_size
            ),
        ));
    }
    if region_size % align_of::<u32>() != 0 {
        return Err(ServiceError::unavailable(
            "mmio_alignment",
            format!("mapped region size is not 32-bit aligned ({region_size})"),
        ));
    }

    let mut offset = 0usize;
    let full_word_limit = data.len() & !0x3;
    while offset < full_word_limit {
        let value = u32::from_le_bytes(
            data[offset..offset + 4]
                .try_into()
                .expect("full-word slice length is fixed"),
        );
        write_word(offset, value)?;
        offset += 4;
    }

    if offset < data.len() {
        let mut tail = [0u8; 4];
        tail[..data.len() - offset].copy_from_slice(&data[offset..]);
        write_word(offset, u32::from_le_bytes(tail))?;
        offset += 4;
    }

    while offset < region_size {
        write_word(offset, 0)?;
        offset += 4;
    }

    Ok(())
}

impl UioInterrupt {
    fn open(path: &Path) -> Result<Self, ServiceError> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|error| {
                ServiceError::unavailable(
                    "open_uio_failed",
                    format!(
                        "failed to open {} for interrupt handling: {error}",
                        path.display()
                    ),
                )
            })?;
        Ok(Self { file })
    }

    fn arm(&mut self) -> Result<(), ServiceError> {
        self.file.write_all(&1u32.to_le_bytes()).map_err(|error| {
            ServiceError::unavailable(
                "arm_irq_failed",
                format!("failed to arm interrupt: {error}"),
            )
        })
    }

    fn wait(&mut self, timeout: Duration) -> Result<u32, ServiceError> {
        let timeout_ms = timeout.as_millis().min(u16::MAX as u128) as u16;
        let mut poll_fds = [PollFd::new(self.file.as_fd(), PollFlags::POLLIN)];
        let ready = poll(&mut poll_fds, timeout_ms).map_err(|error| {
            ServiceError::unavailable(
                "poll_irq_failed",
                format!("failed while waiting for interrupt: {error}"),
            )
        })?;
        if ready == 0 {
            return Err(ServiceError::timeout(
                "irq_wait_timeout",
                format!(
                    "timed out waiting for interrupt after {:.2}s",
                    timeout.as_secs_f64()
                ),
            ));
        }

        let mut data = [0u8; 4];
        self.file.read_exact(&mut data).map_err(|error| {
            ServiceError::unavailable(
                "irq_read_failed",
                format!("failed to read interrupt event counter: {error}"),
            )
        })?;
        Ok(u32::from_le_bytes(data))
    }
}

pub fn error_code_name(value: u8) -> String {
    match value {
        0 => "none".to_string(),
        1 => "message_len".to_string(),
        2 => "job_count".to_string(),
        3 => "job_range".to_string(),
        4 => "job_timeout".to_string(),
        other => format!("unknown({other})"),
    }
}

fn path_uses_uio(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.starts_with("uio"))
        .unwrap_or(false)
}

fn system_page_size() -> Result<u64, ServiceError> {
    let value = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if value <= 0 {
        return Err(ServiceError::unavailable(
            "page_size_unavailable",
            "failed to determine host page size",
        ));
    }
    Ok(value as u64)
}

fn discover_uio_region(
    target_addr: u64,
    requested_size: usize,
) -> Result<Option<RegionSpec>, ServiceError> {
    let sysfs_root = Path::new("/sys/class/uio");
    if !sysfs_root.exists() {
        return Ok(None);
    }

    for entry in fs::read_dir(sysfs_root).map_err(|error| {
        ServiceError::unavailable(
            "enumerate_uio_failed",
            format!("failed to enumerate {}: {error}", sysfs_root.display()),
        )
    })? {
        let entry = entry.map_err(|error| {
            ServiceError::unavailable(
                "enumerate_uio_failed",
                format!("failed to read UIO entry: {error}"),
            )
        })?;
        let path = entry.path();
        let addr_path = path.join("maps/map0/addr");
        let size_path = path.join("maps/map0/size");
        if !(addr_path.exists() && size_path.exists()) {
            continue;
        }

        let region_addr = parse_u64_auto(fs::read_to_string(&addr_path).map_err(|error| {
            ServiceError::unavailable(
                "read_uio_metadata_failed",
                format!("failed to read {}: {error}", addr_path.display()),
            )
        })?)?;
        let region_size = parse_u64_auto(fs::read_to_string(&size_path).map_err(|error| {
            ServiceError::unavailable(
                "read_uio_metadata_failed",
                format!("failed to read {}: {error}", size_path.display()),
            )
        })?)?;

        if region_addr == target_addr && region_size >= requested_size as u64 {
            return Ok(Some(RegionSpec {
                path: PathBuf::from("/dev").join(path.file_name().unwrap()),
                offset: 0,
                size: requested_size,
            }));
        }
    }

    Ok(None)
}

fn parse_u64_auto(raw: String) -> Result<u64, ServiceError> {
    let text = raw.trim();
    let parsed = if let Some(stripped) = text.strip_prefix("0x").or_else(|| text.strip_prefix("0X"))
    {
        u64::from_str_radix(stripped, 16)
    } else {
        text.parse()
    };
    parsed.map_err(|error| {
        ServiceError::unavailable(
            "parse_numeric_metadata_failed",
            format!("failed to parse numeric metadata value {text:?}: {error}"),
        )
    })
}

fn wait_mode_for_layout(
    wait_mode: WaitMode,
    control_path: &Path,
) -> Result<WaitMode, ServiceError> {
    let supports_irq = path_uses_uio(control_path);
    match wait_mode {
        WaitMode::Auto => Ok(WaitMode::Poll),
        WaitMode::Irq if !supports_irq => Err(ServiceError::unavailable(
            "irq_requires_uio",
            "interrupt-driven wait requires the control region to be mapped through /dev/uio",
        )),
        other => Ok(other),
    }
}

fn probe_hardware_identity(control: &MappedRegion) -> Result<HardwareIdentity, ServiceError> {
    let magic = control.read_u32(REG_HW_MAGIC)?;
    if magic != HW_MAGIC {
        return Err(ServiceError::unavailable(
            "hardware_magic_mismatch",
            format!("unexpected hardware magic 0x{magic:08x}; expected 0x{HW_MAGIC:08x}"),
        ));
    }

    let build = control.read_u32(REG_HW_BUILD)?;
    Ok(HardwareIdentity {
        mode: (build & 0xff) as u8,
        api_version: ((build >> 8) & 0xff) as u8,
    })
}

fn require_full_hardware(identity: HardwareIdentity) -> Result<(), ServiceError> {
    if identity.mode != HW_MODE_FULL {
        return Err(ServiceError::unavailable(
            "hardware_mode_mismatch",
            format!(
                "loaded hardware mode is {}; expected full",
                hw_mode_name(identity.mode)
            ),
        ));
    }
    if identity.api_version != HW_API_VERSION {
        return Err(ServiceError::unavailable(
            "hardware_api_mismatch",
            format!(
                "loaded hardware API is {}; expected {}",
                identity.api_version, HW_API_VERSION
            ),
        ));
    }
    Ok(())
}

fn hw_mode_name(mode: u8) -> &'static str {
    match mode {
        HW_MODE_FULL => "full",
        HW_MODE_BRINGUP => "bringup",
        _ => "unknown",
    }
}

fn poll_until_complete(control: &MappedRegion, deadline: Instant) -> Result<u32, ServiceError> {
    loop {
        let status_word = control.read_u32(REG_STATUS)?;
        let status = decode_status(status_word);
        if status.done || status.error {
            return Ok(status_word);
        }
        if Instant::now() >= deadline {
            return Err(ServiceError::timeout(
                "completion_timeout",
                "timed out waiting for accelerator completion",
            ));
        }
        thread::sleep(DEFAULT_POLL_INTERVAL);
    }
}

fn decode_status(word: u32) -> StatusBits {
    StatusBits {
        done: (word & 0x2) != 0,
        error: (word & 0x4) != 0,
    }
}

fn read_result_mask(control: &MappedRegion) -> Result<[u32; 8], ServiceError> {
    let mut value = [0u32; 8];
    for (index, slot) in value.iter_mut().enumerate() {
        *slot = control.read_u32(REG_RESULT_MASK_BASE + index * 4)?;
    }
    Ok(value)
}

fn result_mask_hex(words: &[u32; 8]) -> String {
    let mut text = String::with_capacity(64);
    for word in words.iter().rev() {
        text.push_str(&format!("{word:08x}"));
    }
    text
}

fn mask_bits(words: &[u32; 8], job_count: usize) -> Vec<bool> {
    (0..job_count)
        .map(|bit| {
            let word_index = bit / 32;
            let bit_index = bit % 32;
            ((words[word_index] >> bit_index) & 0x1) != 0
        })
        .collect()
}

fn read_snapshot(control: &MappedRegion) -> Result<SnapshotStatus, ServiceError> {
    let err_status = control.read_u32(REG_SNAPSHOT_ERR_STATUS)?;
    Ok(SnapshotStatus {
        batch_id: control.read_u32(REG_SNAPSHOT_BATCH_ID)?,
        accepted_job_count: (control.read_u32(REG_SNAPSHOT_ACCEPTED)? & 0xff) as u8,
        jobs_completed: control.read_u32(REG_SNAPSHOT_COMPLETED)?,
        jobs_dropped: control.read_u32(REG_SNAPSHOT_DROPPED)?,
        error: ((err_status >> 8) & 0x1) != 0,
        result_valid: ((err_status >> 9) & 0x1) != 0,
        error_code: (err_status & 0xff) as u8,
    })
}

#[cfg(test)]
mod tests {
    use super::{
        write_bytes_as_u32_words, AcceleratorStatus, HardwareBatchRequest, HardwareBatchResult,
        SigverifyAccelerator, SingleFlightAccelerator, VerificationJob, VerifyMode,
    };
    use crate::error::{ErrorKind, ServiceError};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::thread;
    use std::time::Duration;

    struct BlockingAccelerator {
        entered_tx: Mutex<Option<mpsc::Sender<()>>>,
        release_rx: Mutex<mpsc::Receiver<()>>,
    }

    impl SigverifyAccelerator for BlockingAccelerator {
        fn verify_batch(
            &self,
            _request: HardwareBatchRequest,
        ) -> Result<HardwareBatchResult, ServiceError> {
            if let Some(sender) = self.entered_tx.lock().unwrap().take() {
                sender.send(()).unwrap();
            }
            self.release_rx.lock().unwrap().recv().unwrap();
            Ok(success_result())
        }

        fn status(&self) -> AcceleratorStatus {
            ready_status()
        }
    }

    struct ErrorAccelerator {
        calls: AtomicUsize,
    }

    impl SigverifyAccelerator for ErrorAccelerator {
        fn verify_batch(
            &self,
            _request: HardwareBatchRequest,
        ) -> Result<HardwareBatchResult, ServiceError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Err(ServiceError::accelerator(
                "mock_failure",
                "mock accelerator failed",
            ))
        }

        fn status(&self) -> AcceleratorStatus {
            ready_status()
        }
    }

    fn ready_status() -> AcceleratorStatus {
        AcceleratorStatus {
            ready: true,
            fpga_loaded: true,
            control_path: "/dev/uio0".to_string(),
            message_path: "/dev/uio1".to_string(),
            job_path: "/dev/uio2".to_string(),
            last_seen_batch_id: Some(41),
            hardware_mode: Some("full".to_string()),
            hardware_api_version: Some(1),
            detail: None,
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
            last_job_cycles: 100,
            last_batch_cycles: 200,
        }
    }

    fn request_template() -> HardwareBatchRequest {
        HardwareBatchRequest {
            message: vec![0x01, 0x02, 0x03],
            jobs: vec![VerificationJob {
                pubkey: [0x11; 32],
                signature: [0x22; 64],
            }],
            verify_mode: VerifyMode::Strict,
            timeout: Duration::from_millis(50),
            dispatch_limit: 0,
            job_timeout_cycles: 0,
        }
    }

    #[test]
    fn mmio_byte_writer_emits_aligned_words_and_zero_fills_region() {
        let mut writes = Vec::new();

        write_bytes_as_u32_words(&[1, 2, 3, 4, 5, 6], 16, |offset, value| {
            writes.push((offset, value));
            Ok(())
        })
        .unwrap();

        assert_eq!(
            writes,
            vec![
                (0, 0x0403_0201),
                (4, 0x0000_0605),
                (8, 0x0000_0000),
                (12, 0x0000_0000),
            ]
        );
    }

    #[test]
    fn mmio_byte_writer_preserves_exact_words() {
        let mut writes = Vec::new();

        write_bytes_as_u32_words(&[0xaa, 0xbb, 0xcc, 0xdd], 8, |offset, value| {
            writes.push((offset, value));
            Ok(())
        })
        .unwrap();

        assert_eq!(writes, vec![(0, 0xddcc_bbaa), (4, 0x0000_0000)]);
    }

    #[test]
    fn mmio_byte_writer_rejects_oversized_payloads() {
        let error = write_bytes_as_u32_words(&[0; 5], 4, |_, _| unreachable!()).unwrap_err();

        assert_eq!(error.kind, ErrorKind::Limit);
        assert_eq!(error.code, "payload_too_large");
    }

    #[test]
    fn mmio_byte_writer_rejects_unaligned_regions() {
        let error = write_bytes_as_u32_words(&[0; 4], 6, |_, _| unreachable!()).unwrap_err();

        assert_eq!(error.kind, ErrorKind::Unavailable);
        assert_eq!(error.code, "mmio_alignment");
    }

    #[test]
    fn single_flight_rejects_concurrent_verify_requests() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let accelerator = Arc::new(SingleFlightAccelerator::new(BlockingAccelerator {
            entered_tx: Mutex::new(Some(entered_tx)),
            release_rx: Mutex::new(release_rx),
        }));

        let worker_accelerator = accelerator.clone();
        let worker = thread::spawn(move || worker_accelerator.verify_batch(request_template()));

        entered_rx
            .recv_timeout(Duration::from_millis(250))
            .expect("first request never reached the accelerator");

        let error = accelerator.verify_batch(request_template()).unwrap_err();
        assert_eq!(error.kind, ErrorKind::Unavailable);
        assert_eq!(error.code, "accelerator_busy");

        release_tx.send(()).unwrap();
        assert!(worker.join().unwrap().is_ok());
    }

    #[test]
    fn single_flight_releases_lock_after_errors() {
        let inner = ErrorAccelerator {
            calls: AtomicUsize::new(0),
        };
        let accelerator = SingleFlightAccelerator::new(inner);

        let first = accelerator.verify_batch(request_template()).unwrap_err();
        let second = accelerator.verify_batch(request_template()).unwrap_err();

        assert_eq!(first.kind, ErrorKind::Accelerator);
        assert_eq!(second.kind, ErrorKind::Accelerator);
        assert_eq!(accelerator.inner.calls.load(Ordering::SeqCst), 2);
    }
}
