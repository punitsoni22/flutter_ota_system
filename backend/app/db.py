from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from app.config import get_settings

_engine: Engine | None = None
_sessionmaker: sessionmaker[Session] | None = None


def init_engine(url: str | None = None) -> Engine:
    global _engine, _sessionmaker
    url = url or get_settings().database_url
    # Supabase, Neon & co. hand out postgres:// URLs; this app's driver is psycopg 3.
    for prefix in ("postgres://", "postgresql://"):
        if url.startswith(prefix):
            url = "postgresql+psycopg://" + url.removeprefix(prefix)
    kwargs: dict = {"pool_pre_ping": True}
    if url.startswith("sqlite"):
        kwargs["connect_args"] = {"check_same_thread": False}
        if url.startswith("sqlite:///"):
            from pathlib import Path

            Path(url.removeprefix("sqlite:///")).parent.mkdir(parents=True, exist_ok=True)
    else:
        size = get_settings().db_pool_size
        kwargs.update(pool_size=size, max_overflow=size * 2)
    _engine = create_engine(url, **kwargs)
    _sessionmaker = sessionmaker(bind=_engine, autoflush=False, expire_on_commit=False)
    return _engine


def get_engine() -> Engine:
    return _engine or init_engine()


def get_db() -> Iterator[Session]:
    if _sessionmaker is None:
        init_engine()
    assert _sessionmaker is not None
    with _sessionmaker() as session:
        yield session
