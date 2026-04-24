use clap::{Args, Parser, Subcommand};
use hyper::server::conn::http1;
use hyper_util::rt::TokioIo;
use hyper_util::service::TowerToHyperService;
use kv260_sigv_daemon::accelerator::{
    AcceleratorConfig, MappedAccelerator, SingleFlightAccelerator, WaitMode,
};
use kv260_sigv_daemon::build_router;
use std::error::Error;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{error, info};

#[derive(Debug, Parser)]
#[command(name = "kv260_sigv_daemon")]
#[command(about = "Unix-socket HTTP daemon for the KV260 sigverify accelerator")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Serve(ServeArgs),
}

#[derive(Debug, Clone, Args)]
struct ServeArgs {
    #[arg(long, default_value = "/run/kv260-sigv.sock")]
    socket_path: PathBuf,
    #[arg(long, default_value = "auto")]
    control_path: String,
    #[arg(long, default_value = "auto")]
    message_path: String,
    #[arg(long, default_value = "auto")]
    job_path: String,
    #[arg(long, value_parser = parse_u64_auto, default_value = "0xA0000000")]
    control_offset: u64,
    #[arg(long, value_parser = parse_u64_auto, default_value = "0xA0010000")]
    message_offset: u64,
    #[arg(long, value_parser = parse_u64_auto, default_value = "0xA0020000")]
    job_offset: u64,
    #[arg(long, value_enum, default_value_t = WaitMode::Poll)]
    wait_mode: WaitMode,
    #[arg(long, default_value = "info")]
    log_filter: String,
}

fn parse_u64_auto(raw: &str) -> Result<u64, String> {
    if let Some(stripped) = raw.strip_prefix("0x").or_else(|| raw.strip_prefix("0X")) {
        u64::from_str_radix(stripped, 16)
            .map_err(|error| format!("invalid hex value {raw:?}: {error}"))
    } else {
        raw.parse()
            .map_err(|error| format!("invalid numeric value {raw:?}: {error}"))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve(args) => serve(args).await?,
    }
    Ok(())
}

async fn serve(args: ServeArgs) -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(args.log_filter.clone())
        .without_time()
        .init();

    if let Some(parent) = args.socket_path.parent() {
        fs::create_dir_all(parent)?;
    }
    if args.socket_path.exists() {
        fs::remove_file(&args.socket_path)?;
    }

    let config = AcceleratorConfig {
        control_path: args.control_path,
        message_path: args.message_path,
        job_path: args.job_path,
        control_offset: args.control_offset,
        message_offset: args.message_offset,
        job_offset: args.job_offset,
        wait_mode: args.wait_mode,
    };

    let listener = tokio::net::UnixListener::bind(&args.socket_path)?;
    let app = build_router(Arc::new(SingleFlightAccelerator::new(
        MappedAccelerator::new(config),
    )));
    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);

    info!("listening on unix socket {}", args.socket_path.display());
    loop {
        tokio::select! {
            _ = &mut shutdown => {
                break;
            }
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                let app = app.clone();
                tokio::spawn(async move {
                    let io = TokioIo::new(stream);
                    let service = TowerToHyperService::new(app);
                    if let Err(err) = http1::Builder::new()
                        .serve_connection(io, service)
                        .await
                    {
                        error!("connection failed: {err}");
                    }
                });
            }
        }
    }

    if args.socket_path.exists() {
        fs::remove_file(&args.socket_path)?;
    }
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("SIGTERM handler should install");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
