from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account
from ..schemas import AccountPublic, LoginRequest, RegisterRequest, TokenResponse
from ..security import create_access_token, hash_password, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
def register(payload: RegisterRequest, request: Request, db: Session = Depends(get_db)) -> TokenResponse:
    if db.scalar(select(Account).where(Account.email == payload.email)) is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="An account with this email already exists")
    account = Account(
        email=payload.email,
        password_hash=hash_password(payload.password),
        display_name=payload.display_name.strip(),
        role=payload.role,
    )
    db.add(account)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="An account with this email already exists")
    token = create_access_token(
        account.id,
        request.app.state.settings.auth_secret,
        request.app.state.settings.access_token_ttl_seconds,
    )
    return TokenResponse(access_token=token, account=AccountPublic.model_validate(account))


@router.post("/login", response_model=TokenResponse)
def login(payload: LoginRequest, request: Request, db: Session = Depends(get_db)) -> TokenResponse:
    account = db.scalar(select(Account).where(Account.email == payload.email))
    if account is None or not account.is_active or not verify_password(payload.password, account.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid email or password")
    token = create_access_token(
        account.id,
        request.app.state.settings.auth_secret,
        request.app.state.settings.access_token_ttl_seconds,
    )
    return TokenResponse(access_token=token, account=AccountPublic.model_validate(account))


@router.get("/me", response_model=AccountPublic)
def me(account: Account = Depends(get_current_account)) -> AccountPublic:
    return AccountPublic.model_validate(account)
