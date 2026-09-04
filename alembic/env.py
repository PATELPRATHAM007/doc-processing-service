import importlib
import os
import sys
from logging.config import fileConfig
from pathlib import Path

from sqlalchemy import engine_from_config, pool

from alembic import context

# Add project root to sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

from app.core.config import settings  # noqa: E402
from app.db.base import Base  # noqa: E402


# AUTO-DISCOVER AND IMPORT ALL MODULE MODELS
def import_all_module_models():
    """Dynamically import all models.py files from app/modules/*/models.py.

    This ensures all models are registered with SQLAlchemy metadata.
    """
    modules_path = Path("app/modules")

    if not modules_path.exists():
        return

    imported_count = 0
    for module_dir in sorted(modules_path.iterdir()):
        if module_dir.is_dir() and not module_dir.name.startswith("_"):
            models_file = module_dir / "models.py"
            if models_file.exists():
                module_name = f"app.modules.{module_dir.name}.models"
                try:
                    importlib.import_module(module_name)
                    imported_count += 1
                except Exception as e:  # noqa: BLE001
                    print(f"Failed to import {module_name}: {e}")


# Import all models before setting target_metadata
import_all_module_models()

target_metadata = Base.metadata

# Override sqlalchemy.url with the one from settings
config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode."""
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode."""
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
