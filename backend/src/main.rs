//! ASH Backend - Minimal Untrusted Message Relay
//!
//! A privacy-first ephemeral message relay that:
//! - Stores encrypted blobs in RAM only (fixed 5-minute TTL)
//! - Propagates burn signals for conversation destruction
//! - Sends silent push notifications via APNS
//!
//! # Security Properties
//!
//! - No plaintext content ever touches the server
//! - No user identity - only opaque conversation IDs
//! - No long-term storage - data deleted on ACK or expiry
//! - Best-effort delivery - no guaranteed message persistence

use ash_backend::{apns, build_router, config::Config, expiry, handlers::AppState, store::Store};
use std::sync::Arc;
use tracing::info;

#[tokio::main]
async fn main() {
    // Load environment variables from .env file if present
    let _ = dotenvy::dotenv();

    // Initialize structured logging
    init_tracing();

    // Load and validate configuration
    let config = Config::from_env();
    log_startup_info(&config);

    // Initialize core components
    let store = Arc::new(Store::new(config.clone()));
    store.clone().start_cleanup_task();

    let apns = apns::create_client(&config);
    let state = AppState::new(store, apns.clone());
    state
        .transfers
        .clone()
        .start_cleanup_task(std::time::Duration::from_secs(60));

    // Start background workers
    let expiry_worker = Arc::new(expiry::ExpiryWorker::new(state.clone(), apns));
    expiry_worker.start();

    // Build and serve the application
    let app = build_router(state);
    serve(app, &config).await;
}

/// Initialize tracing with environment-based log levels.
fn init_tracing() {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};

    tracing_subscriber::registry()
        .with(fmt::layer())
        .with(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("ash_backend=debug,tower_http=info")),
        )
        .init();
}

/// Log startup configuration (no secrets).
fn log_startup_info(config: &Config) {
    info!(
        bind_addr = %config.bind_addr,
        port = config.port,
        storage = "memory",
        blob_ttl_secs = config.blob_ttl.as_secs(),
        max_ciphertext_size = config.max_ciphertext_size,
        apns_enabled = config.apns_configured(),
        "Starting ASH backend"
    );
}

/// Bind to address and serve the application.
async fn serve(app: axum::Router, config: &Config) {
    let bind_addr = format!("{}:{}", config.bind_addr, config.port);

    let listener = tokio::net::TcpListener::bind(&bind_addr)
        .await
        .expect("Failed to bind to address");

    info!(addr = %bind_addr, "Server listening");

    axum::serve(listener, app).await.expect("Server error");
}
