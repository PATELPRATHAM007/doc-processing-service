# This file is intentional so that Alembic/DB utils can import 'Base' and all models from one place
from app.db.session import Base

__all__ = ["Base"]
