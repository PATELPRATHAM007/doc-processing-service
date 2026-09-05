# Asynchronous Document Processing Microservice

A production-ready asynchronous document processing backend microservice built with **FastAPI**, **Celery**, **Redis**, **PostgreSQL**, **SQLAlchemy 2.0**, and **Google Gemini Multimodal OCR API (`gemini-3.6-flash`)**, orchestrated with **Docker Compose**. Includes a built-in modern, responsive web UI for interactive document upload, real-time asynchronous job status tracking, and structured text analysis.

---

> 🚀 **Live Production Deployment**: [http://156.67.104.24:9000/](http://156.67.104.24:9000/)
> 📖 **Interactive Swagger API Docs**: [http://156.67.104.24:9000/docs](http://156.67.104.24:9000/docs)
> 🔍 **ReDoc Documentation**: [http://156.67.104.24:9000/redoc](http://156.67.104.24:9000/redoc)
> 💓 **Health Check Endpoint**: [http://156.67.104.24:9000/api/v1/health](http://156.67.104.24:9000/api/v1/health)

---

## Interactive Web Interface & User Workflow

The service provides an intuitive, high-contrast web dashboard live at **[http://156.67.104.24:9000/](http://156.67.104.24:9000/)** (or locally at `http://localhost:9000` / `http://0.0.0.0:9000`). It gives users an end-to-end interactive experience to upload documents, monitor asynchronous background workers in real time, and inspect or export extracted text and tables.

### 1. Document Upload Interface

Users can easily upload files via drag-and-drop or file browser:

![Document Upload Interface](docs/images/document-upload-interface.png)

- **Supported Formats**: `.pdf`, `.png`, `.jpg`, `.jpeg`, `.webp`, `.tiff`, `.bmp` (up to 10 MB).
- **Client-Side Validation**: Checks file extensions and sizes instantly, presenting a file preview card with type badges and formatted file sizes.
- **Single-Click Ingestion**: Clicking **"Process Document"** streams the file to `POST /api/v1/documents`. The FastAPI backend computes a SHA-256 hash in 64 KB chunks, writes the file to storage, enqueues the job into Redis, and returns an immediate `202 Accepted` response with a unique `job_id`.

---

### 2. Real-Time Background Processing & Polling

Once submitted, the UI seamlessly transitions into the active processing view:

- **Live Multi-Step Pipeline**:
  1. **Upload Document**: Transmitted and SHA-256 computed.
  2. **Enqueue Background Task**: Claimed by a Celery worker from the Redis queue.
  3. **Multimodal OCR Extraction**: Analyzed with Google Gemini 3.6 Flash for text, tables, and formatting.
  4. **Store Results**: Results committed to PostgreSQL with duplicate detection.
- **Live Elapsed Timer**: Visual stopwatch showing processing duration.
- **Continuous Polling Without Timeouts**: The frontend polls `GET /api/v1/jobs/{id}` every 1.5 seconds without artificial client timeouts. If the AI model encounters transient rate limits or high demand, the worker automatically applies exponential backoff and retries, while the UI dynamically informs the user.
- **Cancel Button**: A "Cancel & Return to Upload" button lets users abort waiting and return to the upload screen at any time.

---

### 3. Extracted Document Output & Results

When the background worker completes processing, the frontend automatically transitions to the comprehensive extraction results screen:

![Document Extraction Result](docs/images/document-extraction-result.png)

#### Explanation of the Output Interface Components:
1. **Document Header Banner**:
   - **Status Badge**: Green `Completed` badge indicating successful worker execution.
   - **AI Model Badge**: Identifies the exact OCR engine used (e.g. `gemini-3.6-flash`).
   - **Document Title**: Clean display of the original uploaded document filename (e.g. `Take-Home Assignment - Python Developer.pdf`).
   - **Job Metadata**: Shows the unique Celery tracking `Job ID` (e.g. `job_8a96181d1ae7`) and total execution duration (`Processed in 37s`).
2. **Document Metrics Bar**:
   - **Character Count**: Exact count of all extracted characters (e.g. `8,163` characters).
   - **Word Count**: Accurate word count calculation (e.g. `1,252` words).
   - **Line Count**: Total line count (e.g. `390` lines).
3. **Interactive Search & Filter**:
   - Real-time client-side text search box (`Find in text...`). Matching terms are highlighted with `<mark>` tags instantly as you type.
4. **Structured Text Container**:
   - Monospace viewer preserving exact document layout, markdown formatting, section headers (`### Problem Statement`), bold tags, bullet points, and tabular structures verbatim.
5. **One-Click Action Toolbar**:
   - **Copy Text**: Copies the entire raw extracted text directly to the system clipboard with instant visual confirmation.
   - **Download .txt**: Downloads the full extracted text as a clean `<filename>_extracted.txt` file directly to your downloads folder.
   - **Process Another**: Resets the viewer and returns to the upload screen for the next document without needing a full page refresh.

---

## System Design & Deep Architecture

The microservice is engineered around a distributed, decoupled, event-driven architecture designed to guarantee **high ingestion throughput**, **sub-10ms upload response times**, **fault isolation**, and **resilient background processing**.

```text
                                  +---------------------------------------+
                                  |            Client / Frontend          |
                                  +---------------------------------------+
                                         |                         ^
       1. POST /api/v1/documents (Upload)|                         | 5. Poll GET /api/v1/jobs/{id}
                                         v                         |    GET /api/v1/jobs/{id}/result
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
                     |  - Atomic DB Job Claim (SELECT FOR UPDATE)   |
                     |  - Content Deduplication (SHA-256 Cache)     |
                     |  - Exponential Backoff Retries (429 / 503)   |
                     +----------------------------------------------+
                                         |
                                         | 5. Multimodal OCR Request
                                         v
                     +----------------------------------------------+
                     |           Google Gemini API                  |
                     |   (gemini-3.6-flash / multimodal model)      |
                     +----------------------------------------------+
```

---

### 1. End-to-End Processing Flow

The lifecycle of an uploaded document transitions across discrete, loosely coupled subsystems:

```mermaid
sequenceDiagram
    autonumber
    actor Client as Client / Browser
    participant API as FastAPI Web Service
    participant DB as PostgreSQL (ACID)
    participant Redis as Redis Message Broker
    participant Worker as Celery Background Worker
    participant Gemini as Google Gemini Multimodal API

    Client->>API: POST /api/v1/documents (multipart/form-data)
    Note over API: Stream 64KB chunks, compute SHA-256,<br/>validate MIME & size (<=10MB)
    API->>DB: INSERT into documents (status: uploaded)<br/>INSERT into jobs (status: queued)
    API->>Redis: Enqueue process_document_task(job_id)
    API-->>Client: 202 Accepted {job_id, document_id, status: uploaded}

    loop Polling Status
        Client->>API: GET /api/v1/jobs/{job_id}
        API->>DB: SELECT status, attempts, error FROM jobs
        API-->>Client: 200 OK {status: processing/completed}
    end

    Worker->>Redis: BRPOP document_processing_queue
    Worker->>DB: SELECT FOR UPDATE job record (status: processing)
    Worker->>DB: Deduplication query (check matching file_hash)
    alt Hash Matches Existing Processed Document
        Note over Worker: Deduplication Hit: Reuse cached extraction in <5ms
        Worker->>DB: INSERT into results (reused text, provider: deduplicated)<br/>UPDATE jobs (status: completed)
    else Unique Document Content
        Worker->>Gemini: POST generateContent (multimodal OCR prompt + document bytes)
        alt Transient Failure (HTTP 429 / 503 / Network Timeout)
            Worker->>DB: Record transient error info (status: processing)
            Worker->>Redis: Re-enqueue task with exponential backoff (retry attempt)
        else Success
            Gemini-->>Worker: Extracted structured text & markdown tables
            Worker->>DB: INSERT into results (extracted_text, char_count)<br/>UPDATE jobs (status: completed)<br/>UPDATE documents (status: processed)
        end
    end

    Client->>API: GET /api/v1/jobs/{job_id}/result
    API->>DB: SELECT extracted_text, char_count, provider FROM results
    API-->>Client: 200 OK {extracted_text, stats, provider}
```

---

### 2. Relational Data Modeling & ER Diagram

The database schema enforces relational integrity, cascade deletes, and indexing tuned for high-speed deduplication lookups and worker concurrency control:

```mermaid
erDiagram
    DOCUMENTS ||--o{ JOBS : "has many (1:N)"
    DOCUMENTS ||--o{ RESULTS : "has (1:N)"
    JOBS ||--|| RESULTS : "produces exactly one (1:1)"

    DOCUMENTS {
        string id PK "doc_ + UUID hex (e.g. doc_a1b2c3d4e5f6)"
        string filename "Original uploaded filename"
        string content_type "MIME type (e.g. application/pdf)"
        int size_bytes "Exact byte length"
        string file_hash "SHA-256 hex digest (INDEXED for dedup)"
        string file_path "Absolute path in uploads storage"
        string status "uploaded | processing | processed | failed"
        datetime created_at "UTC timestamp"
        datetime updated_at "UTC timestamp"
    }

    JOBS {
        string id PK "job_ + UUID hex (e.g. job_9f8e7d6c5b4a)"
        string document_id FK "References documents.id (CASCADE)"
        string status "queued | processing | completed | failed (INDEXED)"
        int attempts "Execution attempt counter (0, 1, 2, 3)"
        string error "Error message or transient retry reason"
        datetime created_at "UTC enqueue timestamp"
        datetime started_at "UTC execution start timestamp"
        datetime completed_at "UTC finish timestamp"
    }

    RESULTS {
        string id PK "res_ + UUID hex (e.g. res_1a2b3c4d5e6f)"
        string job_id FK "References jobs.id (UNIQUE, CASCADE)"
        string document_id FK "References documents.id (CASCADE)"
        string provider "Model provider (e.g. gemini-3.6-flash)"
        int char_count "Extracted character count"
        text extracted_text "Full extracted text with markdown & tables"
        datetime created_at "UTC timestamp"
    }
```

#### Key Schema Design Principles:
1. **Prefixed IDs**: Primary keys use human-readable, domain-prefixed hex IDs (`doc_`, `job_`, `res_`) for unambiguous log tracing and debugging.
2. **Hash Indexing (`file_hash`)**: B-Tree indexed `file_hash` on `documents` allows constant-time $O(1)$ duplicate checking across millions of records.
3. **Status Indexing (`status`)**: B-Tree indexed `jobs.status` accelerates polling queries and periodic watchdog sweeps for stale/hung jobs.
4. **Unique Constraint on `results.job_id`**: Strictly guarantees that a job can produce at most one result row, preventing double-write anomalies under worker retries.

---

### 3. State Machine & Lifecycle Transitions

Documents and asynchronous jobs progress through well-defined, deterministic state transitions:

```mermaid
stateDiagram-v2
    [*] --> Queued : POST /api/v1/documents (202 Accepted)
    Queued --> Processing : Celery Worker Claims Task

    state Processing {
        [*] --> DedupCheck : Verify SHA-256 in DB
        DedupCheck --> ReusingCache : Match Found (<5ms)
        DedupCheck --> GeminiInference : Unique Content

        GeminiInference --> TransientFailure : HTTP 429 / 503 / Timeout
        TransientFailure --> GeminiInference : Retry with Backoff (Attempts < 3)
        TransientFailure --> MaxRetriesExhausted : Attempts >= 3

        GeminiInference --> ExtractionSuccess : Valid Text Extracted
        GeminiInference --> PermanentFailure : HTTP 401 / Corrupt File
    }

    ReusingCache --> Completed : Commit Reused Result
    ExtractionSuccess --> Completed : Commit Extracted Result
    MaxRetriesExhausted --> Failed : Mark Job & Document Failed
    PermanentFailure --> Failed : No Retries (Instant Fail)

    Completed --> [*] : GET /api/v1/jobs/{id}/result (200 OK)
    Failed --> [*] : GET /api/v1/jobs/{id}/result (400 Bad Request)
```

---

### 4. Celery Worker Execution & Queue Mechanics

The background worker architecture is fine-tuned for high-throughput, compute-heavy document processing tasks:

1. **Dedicated Queue Binding**:
   Celery is configured with `task_default_queue = "document_processing_queue"`, isolating document tasks from other application traffic.
2. **Worker Prefetch Multiplier (`worker_prefetch_multiplier = 1`)**:
   By default, Celery prefetches multiple tasks per worker process. For long-running, heterogeneous tasks (e.g. OCR processing that takes 5–35 seconds per document), prefetching causes head-of-line blocking where one worker hoard tasks while other workers sit idle. Setting `worker_prefetch_multiplier = 1` enforces fair task distribution.
3. **Late Acknowledgments (`task_acks_late = True`)**:
   The worker acknowledges a task only **after** execution succeeds and results are persisted in the database. If a worker process abruptly dies (SIGKILL, OOM killer, node failure), the task is never lost.
4. **Re-queueing on Worker Loss (`task_reject_on_worker_lost = True`)**:
   If a worker container crashes during execution, the message broker immediately re-queues the message for another healthy worker to claim.
5. **Startup Connection Resilience (`broker_connection_retry_on_startup = True`)**:
   Ensures that worker processes gracefully wait for Redis to complete boot-up without crashing.

---

### 5. Error Classification & Exponential Backoff Strategy

The service implements a strict error classification hierarchy to distinguish between temporary infrastructure glitches and fatal client/configuration errors:

| Error Category | HTTP / Error Types | Celery Action | Database Update | User Feedback |
|:---|:---|:---|:---|:---|
| **Transient Errors** | HTTP 429 (Rate Limit)<br/>HTTP 500, 502, 503, 504<br/>Socket / Connection Timeout | Automatic Retry with Exponential Backoff (max 3 attempts) | Updates `job.error` with retry notice; preserves `status = processing` | UI displays: *"Worker is backing off & retrying automatically..."* |
| **Permanent Errors** | HTTP 401 (Invalid API Key)<br/>HTTP 400 (Corrupt File)<br/>Invalid MIME / Unreadable bytes | Fail Fast (zero retries) | Sets `job.status = failed`<br/>Sets `document.status = failed` | UI displays exact error details immediately |

#### Exponential Backoff Formula
For transient errors, the task retry countdown is calculated as:
$$\text{countdown} = \min\left(300,\; 2^{\text{attempts}} \times 5\text{s}\right)$$

- **Attempt 1 Failure**: Retries after **5 seconds**
- **Attempt 2 Failure**: Retries after **10 seconds**
- **Attempt 3 Failure**: Retries after **20 seconds**
- **All Retries Exhausted**: Transitions job to `FAILED` with message `Max retries exceeded (3 attempts): <root_cause>`.

---

### 6. Cryptographic Content Deduplication

To prevent redundant API cost and latency, the system implements content-addressable deduplication:
1. **Streaming SHA-256 Hashing**:
   During file upload, bytes are streamed in 64 KB chunks through Python's `hashlib.sha256()`. Memory consumption remains strictly $O(1)$ regardless of file size.
2. **Instant Cache Retrieval**:
   Before dispatching requests to Google Gemini, the worker queries PostgreSQL for any prior document sharing the same `file_hash` with `status = 'processed'`.
3. **Sub-5ms Execution**:
   On a cache hit, the worker copies the previously extracted text into a new `Result` row marked with `provider = "gemini-3.6-flash (deduplicated)"`, completing the job in $< 5\text{ms}$ with zero external LLM API cost.

---

### 7. Observability, Logging & Distributed Tracing

Centralized observability is provided by [`LoggerManager`](file:///Users/mac/Desktop/doc-processing-service/logger_manager.py):

- **Subsystem Category Isolation**: Logs are routed into dedicated category folders: `logs/api/`, `logs/celery/`, `logs/gemini/`, `logs/database/`, `logs/system/`.
- **Automated Size Rotation**: Active log files rotate at **1 GiB** (`LOG_MAX_BYTES = 1073741824`) with a maximum of **3 backups**, automatically purging the oldest backup file on rollover.
- **Request-ID Correlation**: Every HTTP request receives or inherits an `X-Request-ID` UUID header via Starlette middleware, which is logged across all API dispatches and passed into Celery tasks for distributed end-to-end trace correlation.
- **Caller-Stack Preservation**: Logger captures the exact originating filename, function name, and line number without being masked by the logging utility wrapper.

---

## Web Frontend Architecture

The web interface is built directly inside FastAPI without external Node.js build steps or heavy frameworks:

### Technology Stack
- **FastAPI**: Direct HTML streaming and Jinja2 templating.
- **Jinja2**: Modular HTML templates (`app/templates/base.html`, `app/templates/index.html`).
- **Bootstrap 5.3 & Bootstrap Icons**: Responsive grid system and modern icon set via CDN.
- **Vanilla JavaScript**: Zero-dependency client-side logic, drag-and-drop, asynchronous polling, and clipboard handling (`app/static/js/app.js`).
- **Vanilla CSS**: Bespoke styling adhering to the project's strict 4-color design tokens (`app/static/css/style.css`).

### Design & Color Palette Tokens
| Color Code | Name | Role in Interface |
|:---|:---|:---|
| **`#EDEBE4`** | Warm Sand / Canvas | Page background, card surface tints, and badge backgrounds |
| **`#111111`** | Obsidian Black | High-contrast typography, dark headers, and code viewer |
| **`#1D4ED8`** | Royal Cobalt Blue | Primary action buttons ("Process Document"), brand icons, active states |
| **`#F43F5E`** | Vibrant Rose Coral | Error alerts, file removal buttons, and secondary badges |

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
| **Pytest** | 9.x | Comprehensive automated test suite (36 unit/integration tests) |
| **Ruff** | 0.3+ | Fast code linting and style formatting |

---

## Take-Home Assignment & Problem Statement Alignment

This project is engineered to strictly satisfy and exceed every requirement, evaluation criterion, and architectural expectation outlined in the Take-Home Assignment:

> ### Objective
> Build a small backend service that accepts documents and processes them asynchronously.
> The assignment is intended to evaluate your skills in **Python**, **FastAPI**, **REST APIs**, **databases**, **asynchronous processing**, **Redis/RabbitMQ**, **Docker**, **testing**, and **basic distributed-system concepts**.
>
> ### Problem Statement
> Build a backend service that accepts documents for processing and processes them asynchronously using one or more background workers.
> The system should expose REST APIs through FastAPI, persist document/job information in a database, and use Redis or RabbitMQ as a message broker/queue.
> The document-processing step should extract text from a document using either:
> - a local extraction implementation, or
> - an external OCR/document-processing service.
> *You do not need to train or deploy an AI model.*

---

### Evaluation Criteria & Requirements Fulfillment Matrix

| Evaluation Dimension | Assignment Requirement | Project Implementation | Primary File References |
|:---|:---|:---|:---|
| **Python & Modern Typing** | Idiomatic, clean, modular Python 3.11+ code with strict type annotations, docstrings, and robust error handling. | Fully type-annotated with Python 3.11+ syntax, passing 100% strict [`pyright`](file:///Users/mac/Desktop/doc-processing-service/pyproject.toml) type-checking, formatted with Ruff, adhering to clean architecture and SOLID design patterns. | [`app/main.py`](file:///Users/mac/Desktop/doc-processing-service/app/main.py)<br/>[`app/services/document_processor.py`](file:///Users/mac/Desktop/doc-processing-service/app/services/document_processor.py) |
| **FastAPI & REST APIs** | Expose clean, standardized REST APIs for document upload, job status, and results. | Modular, versioned `/api/v1` routes with strict Pydantic v2 schemas ([`DocumentUploadResponse`](file:///Users/mac/Desktop/doc-processing-service/app/schemas/document.py), [`JobStatusResponse`](file:///Users/mac/Desktop/doc-processing-service/app/schemas/job.py), [`JobResultResponse`](file:///Users/mac/Desktop/doc-processing-service/app/schemas/job.py)), unified API response enveloper, streaming chunked file upload, and autogenerated Swagger / ReDoc docs. | [`app/routes/v1/documents.py`](file:///Users/mac/Desktop/doc-processing-service/app/routes/v1/documents.py)<br/>[`app/routes/v1/jobs.py`](file:///Users/mac/Desktop/doc-processing-service/app/routes/v1/jobs.py)<br/>[`app/schemas/`](file:///Users/mac/Desktop/doc-processing-service/app/schemas/) |
| **Database Persistence** | Persist document metadata and asynchronous job status in a relational database. | PostgreSQL 16 + SQLAlchemy 2.0 with indexed UUID hex keys (`doc_`, `job_`, `res_`), foreign key cascades, unique constraints on job results, and automated Alembic schema migrations. | [`app/models/document.py`](file:///Users/mac/Desktop/doc-processing-service/app/models/document.py)<br/>[`app/models/job.py`](file:///Users/mac/Desktop/doc-processing-service/app/models/job.py)<br/>[`alembic/`](file:///Users/mac/Desktop/doc-processing-service/alembic/) |
| **Asynchronous Processing** | Decouple upload ingestion from heavy document processing using background worker(s). | Celery 5.3 prefork worker pool consuming from Redis. `POST /api/v1/documents` validates and saves file in <10ms, returning `202 Accepted` immediately; Celery workers asynchronously handle the OCR pipeline. | [`app/tasks/document_tasks.py`](file:///Users/mac/Desktop/doc-processing-service/app/tasks/document_tasks.py)<br/>[`app/core/celery_app.py`](file:///Users/mac/Desktop/doc-processing-service/app/core/celery_app.py) |
| **Message Broker / Queue** | Use Redis or RabbitMQ as the message broker/queue. | Redis 7 configured as message broker and result store with dedicated queue binding (`document_processing_queue`), late task ACKs (`task_acks_late=True`), re-queuing on worker loss (`task_reject_on_worker_lost=True`), and fair prefetch (`worker_prefetch_multiplier=1`). | [`app/core/config.py`](file:///Users/mac/Desktop/doc-processing-service/app/core/config.py)<br/>[`docker-compose.yml`](file:///Users/mac/Desktop/doc-processing-service/docker-compose.yml) |
| **Document Processing / OCR** | Extract text using local extraction or external OCR service without requiring custom model training. | Pluggable [`DocumentProcessor`](file:///Users/mac/Desktop/doc-processing-service/app/services/document_processor.py) strategy pattern implemented via Google Gemini 3.6 Flash Multimodal OCR API ([`GeminiProcessor`](file:///Users/mac/Desktop/doc-processing-service/app/services/gemini_service.py)), supporting PDF, PNG, JPG, WEBP, TIFF, BMP with full table and markdown extraction. | [`app/services/gemini_service.py`](file:///Users/mac/Desktop/doc-processing-service/app/services/gemini_service.py)<br/>[`app/services/document_processor.py`](file:///Users/mac/Desktop/doc-processing-service/app/services/document_processor.py) |
| **Distributed System Concepts** | Graceful crash recovery, worker scaling, task idempotency, exponential backoff, deduplication. | Cryptographic SHA-256 stream hashing for $O(1)$ duplicate cache bypass (<5ms execution), row-level DB locks (`SELECT FOR UPDATE`), exponential backoff retries for transient 429/503 errors, and max retry caps (3 attempts) to prevent poison pills. | [`app/tasks/document_tasks.py`](file:///Users/mac/Desktop/doc-processing-service/app/tasks/document_tasks.py)<br/>[Distributed System Section](#distributed-systems-architecture--production-considerations) |
| **Docker & Orchestration** | Complete multi-container reproducible environment. | Production-ready [`docker-compose.yml`](file:///Users/mac/Desktop/doc-processing-service/docker-compose.yml) orchestrating 4 health-checked containers (`doc_service_web`, `doc_service_worker`, `doc_service_redis`, `doc_service_db`), with named volumes, network isolation, and automated startup migrations. | [`Dockerfile`](file:///Users/mac/Desktop/doc-processing-service/Dockerfile)<br/>[`docker-compose.yml`](file:///Users/mac/Desktop/doc-processing-service/docker-compose.yml)<br/>[`docker-entrypoint.sh`](file:///Users/mac/Desktop/doc-processing-service/docker-entrypoint.sh) |
| **Testing & Quality Assurance** | Comprehensive automated tests covering happy path and edge cases. | 36 automated Pytest tests validating REST endpoints, validation errors, Celery task lifecycle, transient retry backoff, permanent failure handling, and SHA-256 deduplication. | [`tests/`](file:///Users/mac/Desktop/doc-processing-service/tests/) |

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
- `doc_service_db` (PostgreSQL 16 on `localhost:6432`)
- `doc_service_redis` (Redis 7 on `localhost:7379`)
- `doc_service_web` (FastAPI on `http://localhost:9000`)
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
PORT=9000

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
uvicorn app.main:app --reload --host 0.0.0.0 --port 9000
```

---

## REST API Endpoints & Example cURL Commands

Interactive documentation is available at:
- **Live Swagger UI**: [http://156.67.104.24:9000/docs](http://156.67.104.24:9000/docs) (Local: [http://localhost:9000/docs](http://localhost:9000/docs))
- **Live ReDoc**: [http://156.67.104.24:9000/redoc](http://156.67.104.24:9000/redoc) (Local: [http://localhost:9000/redoc](http://localhost:9000/redoc))

### 1. Upload a Document for Processing

**Endpoint**: `POST /api/v1/documents`
**Status**: `202 Accepted`

```bash
curl -X POST "http://localhost:9000/api/v1/documents" \
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

**Endpoint**: `GET /api/v1/jobs/{job_id}`
**Status**: `200 OK`

```bash
curl -X GET "http://localhost:9000/api/v1/jobs/job_9f8e7d6c5b4a" \
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

**Endpoint**: `GET /api/v1/jobs/{job_id}/result`

- If job is **still in progress**: Returns `202 Accepted`
- If job is **completed**: Returns `200 OK` with extracted text
- If job **failed**: Returns `400 Bad Request` with failure details

```bash
curl -X GET "http://localhost:9000/api/v1/jobs/job_9f8e7d6c5b4a/result" \
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

**Endpoint**: `GET /api/v1/documents/{document_id}`
**Status**: `200 OK`

```bash
curl -X GET "http://localhost:9000/api/v1/documents/doc_a1b2c3d4e5f6" \
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
curl -X GET "http://localhost:9000/api/v1/health"
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

## Future Enhancements & Advanced OCR Model Ecosystem

### 1. Vision-Language Model Integration: PaddleOCR-VL-1.6

While the current architecture leverages Google Gemini Multimodal OCR (`gemini-3.6-flash`) as an external cloud service (aligning with the assignment's rule of not requiring local model training or heavy GPU deployment), a planned high-priority enhancement is the native integration of **[PaddleOCR-VL-1.6](http://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6)**:

- **Hugging Face Model Repository**: [http://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6](http://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6)
- **Architecture**: Vision-Language Model (VLM) engineered by PaddlePaddle specifically for multimodal document intelligence, fine-grained visual text recognition, and complex document layout analysis.

#### Key Advantages of Integrating PaddleOCR-VL-1.6:
1. **Self-Hosted On-Premise Execution (Data Sovereignty)**:
   - Deploys directly onto local or private cloud GPU/CPU worker nodes (via PyTorch / ONNX Runtime / TensorRT).
   - Zero document bytes or extracted text leave the private enterprise network, providing compliance with **HIPAA**, **GDPR**, **SOC 2**, and strict banking regulations.
2. **Zero Recurring Token / API Costs**:
   - Replaces pay-per-token or pay-per-request cloud API billing with fixed infrastructure compute costs. For high-volume enterprise ingestion (hundreds of thousands or millions of documents per month), self-hosting reduces marginal processing costs to near zero.
3. **Uncapped Ingestion & Immunity to Rate Limits**:
   - Eliminates external HTTP 429 quota exhaustion errors, rate limit backoff sleeps, or third-party cloud outages.
4. **Superior Structured Layout & Table Reasoning**:
   - Specifically pre-trained on complex layouts, multi-column technical documents, dense tabular grids, and bordered/borderless financial tables.

---

### 2. The Document Intelligence Ecosystem: Gemini vs. Domain-Specific SOTA Models

Currently, our baseline is **Google Gemini (`gemini-3.6-flash`)**, which delivers outstanding general-purpose zero-shot multimodal document understanding across diverse formats without managing GPU infrastructure.

However, in production enterprise environments, the broader AI ecosystem provides specialized open-source and fine-tuned models that achieve higher precision and specialized accuracy for specific document domains:

```text
+-------------------------------------------------------------------------------------------------+
|                                 DOCUMENT INTELLIGENCE ECOSYSTEM                                 |
+-------------------------------------------------------------------------------------------------+
|                                                                                                 |
|   +--------------------------+    +--------------------------+    +--------------------------+  |
|   |   Generalized Baseline   |    |   Invoices & Receipts    |    |     Handwritten Text     |  |
|   |      Google Gemini       |    |    LayoutLMv3 / Donut    |    |      Microsoft TrOCR     |  |
|   |  - Zero-shot reasoning   |    |  - Spatial 2D coordinates|    |  - Cursive & doctor notes|  |
|   |  - Arbitrary documents   |    |  - Key-value extraction  |    |  - Historical manuscripts|  |
|   |  - Managed cloud API     |    |  - Itemized table bounds |    |  - Form field parsing    |  |
|   +--------------------------+    +--------------------------+    +--------------------------+  |
|                 |                               |                               |               |
|                 +-------------------------------+-------------------------------+               |
|                                                 |                                               |
|                                                 v                                               |
|                                 +-------------------------------+                               |
|                                 |   Complex Tables & Formulas   |                               |
|                                 |   Table-Transformer / Nougat  |                               |
|                                 |   - LaTeX equation parsing    |                               |
|                                 |   - Spanning cells & matrices |                               |
|                                 |   - PaddleOCR-VL-1.6 VLM      |                               |
|                                 +-------------------------------+                               |
+-------------------------------------------------------------------------------------------------+
```

#### Specialized Domain Models Breakdown:

1. **Invoices, Receipts & Financial Bills**:
   - **Specialized Models**: **LayoutLMv3** (Microsoft), **Donut** (Document Understanding Transformer), **DocQuery**.
   - **Why More Precise than General LLMs?**: Financial documents and receipts rely heavily on 2D spatial layouts (e.g. aligning a tax label on the left with a currency amount on the right). LayoutLMv3 unifies textual tokens, visual patches, and 2D bounding-box coordinates to directly extract structured key-value pairs (`vendor_name`, `invoice_number`, `tax_rate`, `line_items[]`) into structured JSON with higher extraction fidelity and lower latency than general LLMs.

2. **Handwritten & Cursive Text**:
   - **Specialized Models**: **TrOCR** (Transformer OCR by Microsoft), **CRNN with CTC loss**.
   - **Why More Precise than General LLMs?**: Scanned handwritten notes, medical prescriptions, and cursive application forms present extreme stroke thickness variability and irregular character spacing. TrOCR leverages an image Transformer encoder coupled with a sequence-to-sequence language decoder pre-trained on large-scale handwriting datasets (IAM Handwriting Database), achieving significantly lower Character Error Rates (CER) on cursive scripts.

3. **Dense Tables & Financial Reports**:
   - **Specialized Models**: **Table-Transformer (TATR)** (Microsoft), **PaddleOCR Table Recognition**.
   - **Why More Precise than General LLMs?**: Multi-page balance sheets and borderless matrices often suffer from column hallucination in general LLMs. Table-Transformer uses object-detection bounding boxes to segment row borders, column separators, and spanning headers, generating syntactically valid HTML `<table>` or CSV formats.

4. **Academic Papers & Mathematical Formulas**:
   - **Specialized Models**: **Nougat** (Neural Optical Understanding for Academic Documents by Meta).
   - **Why More Precise than General LLMs?**: Nougat translates rendered raster page images directly into clean LaTeX syntax, preserving subscript, superscript, fractions, matrices, and scientific citations.

---

### 3. Model Architecture Comparison Matrix

| Model / Architecture | Primary Domain | Deployment Type | Privacy / Data Sovereignty | Latency (avg) | Cost Profile | Best Used For |
|:---|:---|:---|:---|:---|:---|:---|
| **Google Gemini 3.6 Flash** *(Current)* | General multimodal documents, PDF reports, forms | Managed Cloud API | Outbound cloud transmission (requires API key) | ~1.5s – 4.0s | Pay-per-token API pricing | Fast zero-infra setup, diverse unstructured documents, general reasoning |
| **[PaddleOCR-VL-1.6](http://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6)** | Multilingual VLM, structured layouts, tables | Self-hosted / Local GPU | 100% On-Premise (air-gapped compliant) | ~0.5s – 1.8s (GPU) | Fixed infrastructure compute (zero token fees) | Enterprise deployments requiring strict privacy, high throughput, and table parsing |
| **Microsoft TrOCR** | Handwritten notes, cursive forms, prescriptions | Self-hosted / Local GPU or CPU | 100% On-Premise | ~0.3s – 1.0s | Open-source (zero API cost) | Scanned doctor notes, handwritten government/bank forms, cursive text |
| **LayoutLMv3** | Invoices, receipts, tax forms, bills | Self-hosted / Fine-tunable | 100% On-Premise | ~0.2s – 0.8s | Open-source (zero API cost) | Automated accounts payable, receipt reconciliation, structured key-value extraction |
| **Nougat (Meta)** | Academic papers, scientific formulas | Self-hosted / Local GPU | 100% On-Premise | ~1.0s – 2.5s | Open-source (zero API cost) | Scientific publications, LaTeX formula preservation, textbook digitization |

---

### 4. Extensible Multi-Model Architecture (Strategy Pattern)

The service is already structured around the **Strategy Pattern** via [`DocumentProcessor`](file:///Users/mac/Desktop/doc-processing-service/app/services/document_processor.py). Integrating PaddleOCR-VL, TrOCR, or LayoutLM requires zero modifications to FastAPI upload handlers, database schemas, or Celery task queue mechanics:

```python
# app/services/document_processor.py
class DocumentProcessor(ABC):
    @abstractmethod
    def process(self, file_path: Path, content_type: str) -> ExtractedTextResult:
        """Abstract contract for all OCR and document extraction providers."""
        pass


# Planned PaddleOCR-VL Local Processor:
class PaddleOCRVLProcessor(DocumentProcessor):
    def __init__(self, model_repo: str = "PaddlePaddle/PaddleOCR-VL-1.6"):
        # Load local Hugging Face model onto GPU/CPU
        self.model = load_vl_model(model_repo)

    def process(self, file_path: Path, content_type: str) -> ExtractedTextResult:
        extracted_text, metadata = self.model.predict(file_path)
        return ExtractedTextResult(
            text=extracted_text,
            provider="paddleocr-vl-1.6",
            char_count=len(extracted_text),
            raw_metadata=metadata,
        )
```

#### Dynamic Engine Selection Roadmap
Future releases can introduce dynamic engine routing via query parameter or automated document classification:
```bash
# Explicit engine selection via API query parameter:
POST /api/v1/documents?engine=paddleocr-vl
POST /api/v1/documents?engine=trocr
POST /api/v1/documents?engine=layoutlmv3
POST /api/v1/documents?engine=gemini
```
An intelligent upstream classifier can inspect uploaded files (e.g. detecting cursive handwriting vs. invoice structure) and dynamically route the task to the optimal model, maximizing extraction precision, privacy, and cost efficiency.

---

## Testing & Quality Assurance

The project includes an end-to-end automated test suite covering unit, integration, validation, error retry backoff, and deduplication behavior:

```bash
# Run entire test suite (36 tests)
./venv/bin/pytest -v

# Run document processing test suite specifically (13 tests)
./venv/bin/pytest tests/test_document_processing.py -v

# Run static type checker (Pyright)
npx pyright

# Run code linters (Ruff)
./venv/bin/ruff check .

# Check code formatting
./venv/bin/ruff format --check .

# Run all pre-commit hooks
./venv/bin/pre-commit run --all-files
```

All 36 tests pass with zero lint errors and 100% strict type safety.
