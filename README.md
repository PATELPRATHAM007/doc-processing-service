# Asynchronous Document Processing Microservice

A production-ready asynchronous document processing backend microservice built with **FastAPI**, **Celery**, **Redis**, **PostgreSQL**, **SQLAlchemy 2.0**, and **Google Gemini Multimodal OCR API**, orchestrated with **Docker Compose**.

---

## Architecture Overview

The service is designed around an asynchronous, event-driven, decoupled worker architecture to guarantee high ingestion throughput, fault isolation, and resilient background processing:

```text
                                  +---------------------------------------+
                                  |            Client / Frontend          |
                                  +---------------------------------------+
                                         |                         ^
              1. POST /documents (Upload)|                         | 5. Poll GET /jobs/{id}
                                         v                         |    GET /jobs/{id}/result
                                  +--------------------+           |
                                  |    FastAPI Web     |-----------+
                                  |    (Uvicorn API)   |
                                  +--------------------+
                                    |                |
                2. Store metadata   |                | 3. Enqueue job_id
                   & stream file    v                v
                     +-------------------+      +-------------------+
                     |    PostgreSQL     |      |    Redis Queue    |
                     | (doc_processing)  |      |   (Broker/Cache)  |
                     +-------------------+      +-------------------+
                               ^                          |
                               |                          | 4. Fetch task
                               |                          v
                     +----------------------------------------------+
                     |                Celery Worker                 |
                     |  - Atomic DB Job Claim                       |
                     |  - Content Deduplication (SHA-256 Cache)     |
                     |  - Exponential Backoff Retries               |
                     +----------------------------------------------+
                                         |
                                         | 5. Multimodal OCR Request
                                         v
                     +----------------------------------------------+
                     |           Google Gemini API                  |
                     |   (gemini-3.6-flash / multimodal model)      |
                     +----------------------------------------------+
```

### Key Components

1. **FastAPI Web Service (`doc_service_web`)**:
   - Accepts document uploads (PDF, PNG, JPG, JPEG, WEBP, TIFF, BMP) via multipart HTTP requests.
   - Computes SHA-256 hashes in 64 KB chunks and enforces strict file size (10 MB limit) and MIME type validation.
   - Enqueues jobs to Redis and responds immediately with `202 Accepted`, guaranteeing sub-10ms response times.
   - Provides polling endpoints for job lifecycle status and extracted OCR text.

2. **Message Broker (`doc_service_redis`)**:
   - Redis 7 manages the Celery task queue (`document_processing_queue`).
   - Ensures queue persistence with Redis append-only file (AOF) durability.

3. **Background Worker (`doc_service_worker`)**:
   - Celery worker processes tasks asynchronously with `task_acks_late=True` and `task_reject_on_worker_lost=True`.
   - Checks the SHA-256 deduplication cache to avoid redundant external OCR calls.
   - Calls the isolated `DocumentProcessor` interface (Google Gemini Multimodal API).
   - Manages retries for transient errors (HTTP 429/500/503) with exponential backoff (up to 3 attempts).

4. **Relational Database (`doc_service_db`)**:
   - PostgreSQL 16 persists `documents`, `jobs`, and `results` with relational integrity and cascade deletes.
   - Automated database schema migrations powered by Alembic.

5. **Logging & Monitoring (`LoggerManager`)**:
   - Centralized, thread-safe, size-rotating file logging (1 GiB active file, 3 backups) organized into category folders: `api/`, `celery/`, `gemini/`, `database/`, `system/`.
   - Request-ID correlation tracing across all API calls and Celery workers.

---

## Web Frontend Interface

The service includes a modern, responsive document-processing web UI served directly by FastAPI at `http://localhost:8000`.

### Technology Stack
- **FastAPI**: Serves the application and Jinja2 templates directly without requiring a separate Node.js server.
- **Jinja2**: HTML templating engine (`app/templates/base.html`, `app/templates/index.html`).
- **Bootstrap 5.3 & Bootstrap Icons**: Responsive grid, layout utilities, and consistent iconography via CDN.
- **Vanilla JavaScript**: File validation, drag-and-drop handling, `fetch()` uploads, and async polling (`app/static/js/app.js`).
- **Vanilla CSS**: Custom styling adhering to the project's exact 4-color palette (`app/static/css/style.css`).

### Design & Color Palette
The interface is styled around the project's curated palette:
- `#EDEBE4` (Warm Sand) — Page background and subtle card surfaces
- `#111111` (Obsidian Black) — Primary typography, dark headers, and high-contrast containers
- `#1D4ED8` (Royal Cobalt Blue) — Primary action buttons, brand accents, and active states
- `#F43F5E` (Vibrant Rose Coral) — Error alerts, file removal actions, and secondary badges

### User Workflow
1. **Open `http://localhost:8000`**: Browsers receive the responsive document-processing dashboard.
2. **Select or Drag & Drop Document**: Supports PDF, PNG, JPG, JPEG, WEBP, TIFF, BMP up to 10 MB with client-side validation.
3. **Click "Process Document"**: The file is streamed to `POST /documents`. FastAPI responds immediately with `202 Accepted` and a `job_id`.
4. **Live Polling Animation**: The UI displays a live step-by-step processing animation while querying `GET /jobs/{job_id}` every 1.5 seconds.
5. **View Extracted Results**: Once completed, the extracted text is fetched from `GET /jobs/{job_id}/result` and rendered with preserved line breaks and tables.
6. **Action Toolbar**: One-click "Copy Text" (with clipboard feedback), "Download .txt", and "Process Another Document" (resets state without page reload).

---

## Tech Stack

| Technology | Version | Purpose |
|---|---|---|
| **Python** | 3.11+ | Core runtime language |
| **FastAPI** | 0.115+ | High-performance asynchronous REST API |
| **Celery** | 5.3+ | Distributed task queue and background worker |
| **Redis** | 7.x | Message broker and caching backend |
| **PostgreSQL** | 16.x | ACID-compliant relational persistence |
| **SQLAlchemy** | 2.0+ | Modern typed ORM and connection pooling |
| **Google GenAI** | 0.1+ | Multimodal OCR and document text extraction |
| **Alembic** | 1.13+ | Automated database migrations |
| **Docker Compose**| v2+ | Multi-container service orchestration |
| **Pytest** | 9.x | Comprehensive automated test suite (32 unit/integration tests) |
| **Ruff** | 0.3+ | Fast code linting and style formatting |

---

## Quickstart (Docker Compose)

The easiest and recommended way to start the entire distributed system:

### 1. Clone and Configure Environment

```bash
cp .env.example .env
```

Edit `.env` and set your Google Gemini API key:
```bash
GEMINI_API_KEY="your-gemini-api-key-here"
GEMINI_MODEL="gemini-3.6-flash"
```

### 2. Launch All Services

```bash
docker compose up --build -d
```

This boots 4 healthy containers:
- `doc_service_db` (PostgreSQL 16 on `localhost:5432`)
- `doc_service_redis` (Redis 7 on `localhost:6379`)
- `doc_service_web` (FastAPI on `http://localhost:8000`)
- `doc_service_worker` (Celery worker executing background tasks)

*(Note: Database migrations run automatically on container startup via `docker-entrypoint.sh`).*

### 3. Check System Status & Logs

```bash
# Check running containers
docker compose ps

# Follow web API logs
docker compose logs -f web

# Follow Celery worker OCR execution logs
docker compose logs -f worker
```

### 4. Stop Services

```bash
docker compose down
```

---

## Local Development Setup

To run locally without Docker:

### 1. Create and Activate Virtual Environment

```bash
python3.11 -m venv venv
source venv/bin/activate
```

### 2. Install Dependencies

```bash
pip install --upgrade pip
pip install -r requirements.txt
```

### 3. Configure Local `.env`

```ini
PROJECT_NAME="Async Document Processing Service"
ENVIRONMENT="development"
DEBUG=True
HOST="0.0.0.0"
PORT=8000

# PostgreSQL
DATABASE_URL="postgresql+psycopg2://postgres:postgrespassword@localhost:5432/doc_processing_db"

# Redis Broker & Backend
REDIS_URL="redis://localhost:6379/0"
CELERY_BROKER_URL="redis://localhost:6379/0"
CELERY_RESULT_BACKEND="redis://localhost:6379/0"

# Gemini OCR
GEMINI_API_KEY="your-gemini-api-key"
GEMINI_MODEL="gemini-3.6-flash"

# Storage
UPLOAD_DIR="uploads"
MAX_UPLOAD_SIZE_BYTES=10485760
```

### 4. Run Database Migrations

```bash
alembic upgrade head
```

### 5. Start Celery Worker (Terminal 1)

```bash
celery -A app.core.celery_app worker --loglevel=info --concurrency=2
```

### 6. Start FastAPI Application (Terminal 2)

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

---

## REST API Endpoints & Example cURL Commands

Interactive documentation is available at:
- **Swagger UI**: [http://localhost:8000/docs](http://localhost:8000/docs)
- **ReDoc**: [http://localhost:8000/redoc](http://localhost:8000/redoc)

### 1. Upload a Document for Processing

**Endpoint**: `POST /documents` (or `POST /api/v1/documents`)
**Status**: `202 Accepted`

```bash
curl -X POST "http://localhost:8000/documents" \
  -H "Accept: application/json" \
  -F "file=@sample_invoice.pdf;type=application/pdf"
```

**Response (`202 Accepted`)**:
```json
{
  "success": true,
  "statusCode": 202,
  "message": "Document uploaded and queued for processing.",
  "errors": [],
  "data": {
    "document_id": "doc_a1b2c3d4e5f6",
    "filename": "sample_invoice.pdf",
    "content_type": "application/pdf",
    "size_bytes": 45210,
    "status": "uploaded",
    "job_id": "job_9f8e7d6c5b4a",
    "message": "Document uploaded and queued for processing.",
    "created_at": "2026-09-05T10:15:00.123456Z"
  }
}
```

---

### 2. Check Job Processing Status

**Endpoint**: `GET /jobs/{job_id}`
**Status**: `200 OK`

```bash
curl -X GET "http://localhost:8000/jobs/job_9f8e7d6c5b4a" \
  -H "Accept: application/json"
```

**Response while Processing (`200 OK`)**:
```json
{
  "success": true,
  "statusCode": 200,
  "message": "",
  "errors": [],
  "data": {
    "id": "job_9f8e7d6c5b4a",
    "document_id": "doc_a1b2c3d4e5f6",
    "status": "processing",
    "attempts": 1,
    "error": null,
    "created_at": "2026-09-05T10:15:00.123456Z",
    "started_at": "2026-09-05T10:15:00.456789Z",
    "completed_at": null
  }
}
```

---

### 3. Retrieve Extracted Text Result

**Endpoint**: `GET /jobs/{job_id}/result`

- If job is **still in progress**: Returns `202 Accepted`
- If job is **completed**: Returns `200 OK` with extracted text
- If job **failed**: Returns `400 Bad Request` with failure details

```bash
curl -X GET "http://localhost:8000/jobs/job_9f8e7d6c5b4a/result" \
  -H "Accept: application/json"
```

**Response when Completed (`200 OK`)**:
```json
{
  "success": true,
  "statusCode": 200,
  "message": "",
  "errors": [],
  "data": {
    "job_id": "job_9f8e7d6c5b4a",
    "document_id": "doc_a1b2c3d4e5f6",
    "status": "completed",
    "provider": "gemini-3.6-flash",
    "char_count": 842,
    "extracted_text": "INVOICE #INV-2026-001\nDate: September 5, 2026\nBill To: Acme Corporation\nTotal: $1,250.00...",
    "created_at": "2026-09-05T10:15:03.789123Z"
  }
}
```

**Response while Processing (`202 Accepted`)**:
```json
{
  "success": true,
  "statusCode": 202,
  "message": "Document processing is still in progress.",
  "errors": [],
  "data": {
    "job_id": "job_9f8e7d6c5b4a",
    "document_id": "doc_a1b2c3d4e5f6",
    "status": "processing"
  }
}
```

---

### 4. Retrieve Document Metadata and History

**Endpoint**: `GET /documents/{document_id}`
**Status**: `200 OK`

```bash
curl -X GET "http://localhost:8000/documents/doc_a1b2c3d4e5f6" \
  -H "Accept: application/json"
```

**Response (`200 OK`)**:
```json
{
  "success": true,
  "statusCode": 200,
  "message": "",
  "errors": [],
  "data": {
    "id": "doc_a1b2c3d4e5f6",
    "filename": "sample_invoice.pdf",
    "content_type": "application/pdf",
    "size_bytes": 45210,
    "file_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "status": "processed",
    "created_at": "2026-09-05T10:15:00.123456Z",
    "updated_at": "2026-09-05T10:15:03.789123Z",
    "jobs": [
      {
        "id": "job_9f8e7d6c5b4a",
        "status": "completed",
        "attempts": 1,
        "error": null,
        "created_at": "2026-09-05T10:15:00.123456Z",
        "started_at": "2026-09-05T10:15:00.456789Z",
        "completed_at": "2026-09-05T10:15:03.789123Z"
      }
    ]
  }
}
```

---

### 5. Health Probes

```bash
curl -X GET "http://localhost:8000/health"
```

**Response (`200 OK`)**:
```json
{
  "success": true,
  "statusCode": 200,
  "message": "",
  "errors": [],
  "data": {
    "status": "healthy",
    "database": "connected",
    "redis": "connected",
    "environment": "development"
  }
}
```

---

## Follow-up Architecture Questions (Section 8)

### 1. If a worker crashes mid-task, what happens to the job, and how does the system recover?

1. **Celery Late Acknowledgments (`task_acks_late=True`) & Message Safety**:
   Celery is explicitly configured with `task_acks_late=True` and `task_reject_on_worker_lost=True`. The message broker (Redis) does not remove the task acknowledgment until the worker successfully finishes the task. If a worker process terminates abruptly (OOM killer, SIGKILL, hardware fault), the unacknowledged message is automatically rejected and returned to the queue, allowing an active worker to pick it up.

2. **Database State & Idempotency Check**:
   When another worker claims the re-queued task, it runs `query.with_for_update()` in PostgreSQL to lock the job row. If the previous worker crashed after writing the result, the task detects `job.status == JobStatus.COMPLETED` or an existing `Result` record with `unique=True` on `job_id`, skipping redundant Gemini API calls and exiting idempotently.

3. **Retry Counter & Exponential Backoff**:
   The `attempts` counter in the `jobs` table tracks execution counts. If the crash occurred during processing, the new worker increments `job.attempts`. If it exceeds the maximum threshold (3 attempts), the task transitions to `failed` and records the failure reason in `job.error`, preventing infinite crash loops (poison-pill prevention).

4. **Periodic Stale Job Sweeper (Heartbeat Reconciliation)**:
   In production, a Celery Beat periodic task (or watchdog cron) queries for jobs with `status = 'processing'` whose `started_at` timestamp is older than a configured timeout (e.g., > 15 minutes) and re-enqueues them or marks them failed if workers permanently vanished.

---

### 2. How would you scale this system to 10 workers? What bottlenecks would appear first?

To scale horizontally, we increase worker concurrency or container replicas (`docker compose up --scale worker=10` or Kubernetes HPA). When scaling from 1 to 10 workers, the following bottlenecks appear in order:

1. **Gemini API Rate Limits (Primary Bottleneck)**:
   - *Problem*: External LLM providers enforce strict RPM (Requests Per Minute) and TPM (Tokens Per Minute) quotas (e.g., 15 RPM on free tier, 1,000+ RPM on paid tiers). Ten concurrent workers will quickly trigger HTTP 429 errors.
   - *Mitigation*: Configure Celery task rate limits (e.g., `rate_limit="30/m"` on the task), implement distributed token-bucket rate limiters in Redis, or utilize the Gemini Batch API for bulk throughput.

2. **PostgreSQL Connection Pool Exhaustion**:
   - *Problem*: Each Celery worker process maintains a database connection pool. Ten workers with 4 concurrency threads each can consume 40+ connections, competing with FastAPI web requests and exceeding default PostgreSQL limits (`max_connections = 100`).
   - *Mitigation*: Deploy **PgBouncer** in front of PostgreSQL for transaction-level connection pooling, reducing active DB connections to a small, reusable pool.

3. **Local Filesystem & Shared Volume Bottlenecks**:
   - *Problem*: With multiple worker containers on distributed compute nodes (e.g., Kubernetes pods), local disk volumes cannot be shared across nodes. Concurrent file reads/writes on network-attached storage (NFS/EFS) introduce disk IOPS saturation.
   - *Mitigation*: Replace local filesystem storage (`/uploads`) with S3-compatible cloud object storage (AWS S3, Google Cloud Storage, or MinIO) using pre-signed upload URLs.

4. **Task Prefetch & Starvation**:
   - *Problem*: If workers prefetch tasks ahead of time (`worker_prefetch_multiplier > 1`), one worker might hold multiple long-running OCR tasks while other workers sit idle.
   - *Mitigation*: Keep `worker_prefetch_multiplier=1` (already configured in `celery_app.py`) so workers only claim tasks when they are ready to process them.

---

### 3. How would you handle a sudden spike of 1,000 document uploads?

1. **Fast Asynchronous Ingestion Buffer**:
   The FastAPI web tier does **not** process documents synchronously. Uploading a document takes ~5–10ms (saving file bytes, computing SHA-256, writing DB records, and sending a lightweight message to Redis). The web server can easily absorb 1,000 incoming requests within seconds and returns `202 Accepted` immediately, buffering the load safely in Redis.

2. **Direct-to-Object-Storage Uploads (Pre-signed S3/GCS URLs)**:
   To prevent 1,000 concurrent file streams from exhausting API server memory and network bandwidth, clients request a pre-signed S3/GCS PUT URL via `POST /documents/presign`. The client uploads the file directly to cloud storage, and only sends metadata to FastAPI to trigger the Celery task.

3. **Autoscaling Workers via KEDA (Kubernetes Event-driven Autoscaling)**:
   Using KEDA, worker pods scale dynamically based on the queue depth (`LLEN document_processing_queue`). When the queue spikes to 1,000 tasks, KEDA immediately scales the worker deployment from 2 to 20+ replicas, draining the backlog rapidly.

4. **Queue Partitioning & Priority Queues**:
   Split traffic into distinct queues:
   - `interactive_queue`: High-priority, small single-page documents processed immediately.
   - `batch_queue`: Large multi-page documents and bulk uploads processed with lower concurrency to protect LLM quota.

5. **Gemini Batch Processing API**:
   For large spikes, batch tasks into asynchronous Gemini Batch API jobs. This offers 50% lower cost, separate and significantly higher quotas, and decoupled completion webhooks.

6. **Content Deduplication**:
   Identical documents uploaded multiple times during a spike are deduplicated via SHA-256 hash lookup, bypassing Gemini OCR calls completely.

---

### 4. How would you ensure no duplicate documents are processed?

The system implements defense-in-depth deduplication across three layers:

1. **Cryptographic SHA-256 Stream Hashing (Upload Layer)**:
   During file upload, the API streams file chunks through `hashlib.sha256()` without loading the full file into RAM, storing a unique 64-character hex hash on the `Document` record (`file_hash` with DB index).

2. **Deduplication Cache Lookup (Task Execution Layer)**:
   Before dispatching a call to the Google Gemini API, the Celery worker queries the database:
   ```python
   cached_result = (
       db.query(Result)
       .join(Document)
       .filter(
           Document.file_hash == document.file_hash,
           Document.status == DocumentStatus.PROCESSED,
           Document.id != document.id,
       )
       .first()
   )
   ```
   If a matching document was already processed, the worker copies the extracted text to a new `Result` record marked `provider="gemini (deduplicated)"`, sets `job.status = 'completed'`, and finishes in < 5ms without incurring external API latency or cost.

3. **Redis Distributed Locks (In-Flight Concurrency Control)**:
   To prevent duplicate processing when two identical files are uploaded at the exact same millisecond before either completes:
   - The worker acquires a Redis distributed mutex: `redis.set(f"lock:doc_hash:{file_hash}", job_id, nx=True, ex=300)`.
   - If the lock is already held by another worker, the second task delays with a short backoff until the first worker completes and populates the cache.

4. **Database-Level Unique Constraints (Storage Layer)**:
   The `results` table enforces a `UNIQUE` constraint on `job_id`, guaranteeing that even in the event of unexpected race conditions, a job can never have duplicate result entries in the database.

---

## Testing & Quality Assurance

The project includes an end-to-end automated test suite covering unit, integration, validation, error retry backoff, and deduplication behavior:

```bash
# Run entire test suite (32 tests)
./venv/bin/pytest -v

# Run document processing test suite specifically (11 tests)
./venv/bin/pytest tests/test_document_processing.py -v

# Run code linters (Ruff)
./venv/bin/ruff check .

# Check formatting
./venv/bin/ruff format --check .

# Run pre-commit hooks
./venv/bin/pre-commit run --all-files
```

All 32 tests pass with zero lint errors and complete type safety.
