# Async Document Processing Service

A robust, production-ready asynchronous document processing microservice built with **FastAPI**, **PostgreSQL**, **Redis**, **SQLAlchemy 2.0**, and **Docker**.

---

## Features

- **FastAPI Core**: High-performance asynchronous API with automatic interactive OpenAPI (Swagger & ReDoc) documentation.
- **Consistent Response Standard**: All API JSON responses are standardized via `StandardResponseMiddleware`:
  ```json
  {
    "success": true,
    "statusCode": 200,
    "message": "",
    "errors": [],
    "data": { ... }
  }
  ```
- **Request Tracing & Contextual Logging**: `RequestContextMiddleware` automatically generates/adopts `X-Request-ID`, extracts user authentication context, measures execution time, and injects `[req=<id> user=<id>]` into every log line.
- **Service Layer Architecture**: Clean, class-based services (`DatabaseService`, `RedisService`, `SecurityService`) featuring lazy pool initialization, health probes, and graceful shutdown disposal.
- **Automated Migrations**: Docker entrypoint automatically executes `alembic upgrade head` before starting the application, eliminating manual migration steps.
- **Docker Compose Setup**: Pre-configured containers for the web application (`doc_service_web`), database (`doc_service_db`), and Redis cache/broker (`doc_service_redis`).
- **Code Quality**: Pre-configured with `ruff`, `pre-commit`, `pyright`, and comprehensive `pytest` test suites.

---

## Tech Stack

| Technology | Purpose |
|---|---|
| **Python 3.11** | Runtime language |
| **FastAPI** | Web framework |
| **Uvicorn** | ASGI server |
| **SQLAlchemy 2.0** | SQL ORM & connection management |
| **PostgreSQL 16** | Relational database |
| **Redis 7** | Broker, caching, and task queue backend |
| **Alembic** | Database migrations |
| **Docker & Docker Compose** | Containerization & orchestration |
| **Pytest** | Test runner |
| **Ruff & Pyright** | Linting, formatting & static type checking |

---

## Project Structure

```text
.
├── alembic/                  # Database migration scripts and environment
│   ├── versions/             # Migration version files
│   └── env.py                # Alembic runtime config
├── alembic.ini               # Alembic configuration
├── app/
│   ├── api/
│   │   └── v1/               # Version 1 API routes
│   │       ├── endpoints/    # Individual route endpoints (health, etc.)
│   │       └── router.py     # Aggregated v1 router
│   ├── core/                 # Core application configuration & utilities
│   │   ├── config.py         # Pydantic Settings & environment parsing
│   │   ├── create_application.py # FastAPI application factory
│   │   ├── database.py       # Database service re-exports
│   │   ├── exception_handlers.py # Global exception handlers
│   │   ├── lifespan.py       # Startup / shutdown lifecycle & connection cleanup
│   │   ├── logging_config.py # Unified logging configuration & context filter
│   │   ├── messages.py       # Centralized message and log format constants
│   │   ├── middleware/       # Custom ASGI middleware
│   │   │   ├── request_context.py   # Request ID, auth tracing & duration logging
│   │   │   └── standard_response.py # Uniform JSON API envelope
│   │   ├── redis.py          # RedisService connection pool & health checks
│   │   ├── routers.py        # Central route registration
│   │   ├── security.py       # SecurityService token decoding & verification
│   │   └── setup_middleware.py # Middleware pipeline configuration
│   ├── db/
│   │   ├── base.py           # Declarative base for models
│   │   └── session.py        # DatabaseService & session factory
│   ├── modules/              # Domain-specific business modules
│   ├── routes/
│   │   └── root.py           # Root endpoint and probes
│   └── main.py               # Application entry point
├── tests/                    # Unit and integration test suite
│   ├── test_main.py          # Health & root endpoint tests
│   └── test_middleware.py    # Middleware & security unit tests
├── docker-compose.yml        # Multi-container service definitions
├── docker-entrypoint.sh      # Container entrypoint with wait logic & auto-migration
├── Dockerfile                # Production Docker image definition
├── pyrightconfig.json        # Pyright type checker settings
├── pytest.ini               # Pytest configuration
├── requirements.txt          # Python project dependencies
└── README.md
```

---

## Quickstart (Docker Compose)

The fastest way to run the entire service stack with PostgreSQL and Redis:

### 1. Clone the repository and copy environment file
```bash
cp .env.example .env
```

### 2. Start all services
```bash
docker compose up --build -d
```

### 3. Check logs
```bash
docker compose logs -f web
```

### 4. Stop services
```bash
docker compose down
```
*(Tip: Use `docker compose down --remove-orphans` if modifying service or container names).*

---

## Local Development Setup

If you prefer running the application locally outside Docker:

### 1. Create and activate a virtual environment
```bash
python3 -m venv venv
source venv/bin/activate
```

### 2. Install dependencies
```bash
pip install --upgrade pip
pip install -r requirements.txt
```

### 3. Configure environment variables
Ensure `.env` contains valid connection URLs for local PostgreSQL and Redis instances:
```bash
PROJECT_NAME="Async Document Processing Service"
ENVIRONMENT="development"
DEBUG=True
HOST="0.0.0.0"
PORT=8000
DATABASE_URL="postgresql+psycopg2://postgres:postgrespassword@localhost:5432/doc_processing_db"
REDIS_URL="redis://localhost:6379/0"
```

### 4. Run database migrations
```bash
alembic upgrade head
```

### 5. Start the development server
```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

---

## API Documentation & Endpoints

Once the application is running, access the interactive API docs:
- **Interactive Swagger UI**: [http://localhost:8000/docs](http://localhost:8000/docs)
- **ReDoc UI**: [http://localhost:8000/redoc](http://localhost:8000/redoc)
- **OpenAPI JSON**: [http://localhost:8000/openapi.json](http://localhost:8000/openapi.json)

### Core Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Root service metadata |
| `GET` | `/health` | Root-level health probe (Database & Redis connectivity) |
| `GET` | `/api/v1/health` | Versioned health probe |

---

## Standard Response Format

All JSON endpoints return the standardized envelope:

### Success Response (`2xx`)
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

### Error Response (`4xx` / `5xx`)
```json
{
  "success": false,
  "statusCode": 404,
  "message": "Not Found",
  "errors": [],
  "data": {}
}
```

Every response also includes the `X-Request-ID` HTTP header for distributed log correlation.

---

## Database Migrations (Alembic)

To create a new database migration after modifying models in `app/modules/*/models.py`:

```bash
# Generate a new migration script
alembic revision --autogenerate -m "describe changes"

# Apply migrations
alembic upgrade head

# Rollback one migration
alembic downgrade -1
```

*(Note: Migrations run automatically on `docker compose up` via `docker-entrypoint.sh`).*

---

## Testing & Code Quality

### Run Test Suite
```bash
./venv/bin/pytest -v
```

### Run Linter
```bash
./venv/bin/ruff check .
```

### Run Type Checker
```bash
npx pyright app tests
```

### Run Pre-commit Hooks
```bash
./venv/bin/pre-commit run --all-files
```

---

## License

Internal proprietary service. All rights reserved.
