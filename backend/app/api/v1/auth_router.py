# routers/auth_router.py
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import hash_password
from models.user_rbac_model import User
from models.role_model import Role
from models.organization_model import Organization
from schemas.user_schema import DonorRegisterRequest, UserResponse
from schemas.organization_schema import OrganizationRegisterRequest, OrganizationResponse

router = APIRouter(prefix="/auth", tags=["auth"])


def _email_taken(db: Session, email: str) -> bool:
    return db.query(User).filter(func.lower(User.email) == email.lower()).first() is not None


@router.post("/register/donor", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def register_donor(payload: DonorRegisterRequest, db: Session = Depends(get_db)):
    if _email_taken(db, payload.email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    donor_role = db.query(Role).filter(Role.role_name == "Individual Donor").first()
    if donor_role is None:
        raise HTTPException(status_code=500, detail="Role configuration missing")

    new_user = User(
        first_name=payload.first_name,
        last_name=payload.last_name,
        email=payload.email,
        password_hash=hash_password(payload.password),
        contact_number=payload.contact_number,
        id_document_url=payload.id_document_url,
        role_id=donor_role.role_id,
        organization_id=None,
        must_change_password=False,  # they chose this password themselves
    )
    db.add(new_user)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Email already registered")
    db.refresh(new_user)
    return new_user


@router.post("/register/organization", response_model=OrganizationResponse, status_code=status.HTTP_201_CREATED)
def register_organization(payload: OrganizationRegisterRequest, db: Session = Depends(get_db)):
    if _email_taken(db, payload.contact_email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")
    if db.query(Organization).filter(Organization.registration_no == payload.registration_no).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Registration number already used")

    org_role = db.query(Role).filter(Role.role_name == "Relief Organization").first()
    if org_role is None:
        raise HTTPException(status_code=500, detail="Role configuration missing")

    new_org = Organization(
        org_name=payload.org_name,
        organization_type=payload.organization_type,
        address=payload.address,
        contact_person=payload.contact_person,
        registration_no=payload.registration_no,
        contact_email=payload.contact_email,
        legitimacy_document_url=payload.legitimacy_document_url,
    )
    db.add(new_org)
    db.flush()

    new_user = User(
        first_name=payload.contact_person,  # capped at 50 chars in the schema
        last_name="",                        # manuscript doesn't split org contact name
        email=payload.contact_email,
        password_hash=hash_password(payload.password),
        contact_number=payload.contact_number,
        role_id=org_role.role_id,
        organization_id=new_org.organization_id,
        must_change_password=False,
    )
    db.add(new_user)
    # Login stays blocked by authenticate_user() until the admin approves the org.
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Email or registration number already exists")
    db.refresh(new_org)
    return new_org