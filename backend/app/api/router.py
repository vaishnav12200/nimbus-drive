"""Aggregates every versioned route module under the `/api` prefix."""

from __future__ import annotations

from fastapi import APIRouter

from app.api.routes import auth, files, folders, search, shares, sync, telegram

api_router = APIRouter()

api_router.include_router(auth.router)
api_router.include_router(telegram.router)
api_router.include_router(files.router)
api_router.include_router(folders.router)
api_router.include_router(search.router)
api_router.include_router(sync.router)
api_router.include_router(shares.router)
