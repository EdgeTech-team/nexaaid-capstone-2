# routers/admin_router.py
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import hash_password, require_role      # [NOT SPECIFIED — confirm exact signature]
from models.user_rbac_model import User
from models.role_model import Role
from schemas.user_schema import InternalAccountCreateRequest, UserResponse, INTERNAL_ROLES

router = APIRouter(prefix="/admin", tags=["admin"])

@router.post("/users", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def create_internal_account(
    payload: InternalAccountCreateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("Administrator")),
):
    if payload.role_name not in INTERNAL_ROLES:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"role_name must be one of: {', '.join(sorted(INTERNAL_ROLES))}")

    if payload.role_name == "Barangay Receiving Representative" and payload.assigned_barangay_id is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
            detail="assigned_barangay_id is required for this role")

    if db.query(User).filter(User.email == payload.email).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    role = db.query(Role).filter(Role.role_name == payload.role_name).first()
    if role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_user = User(
        first_name=payload.first_name, last_name=payload.last_name,
        email=payload.email, password_hash=hash_password(payload.password),
        contact_number=payload.contact_number, role_id=role.role_id,
        assigned_barangay_id=payload.assigned_barangay_id,   # works now — the model actually declares this column
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    return new_user