# routers/auth_router.py
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from core.database import get_db                     # [NOT SPECIFIED — confirm against Mark's real dependency name]
from core.auth import hash_password                    # [NOT SPECIFIED — confirm against Mark's real function name]
from models.user_rbac_model import User
from models.role_model import Role
from models.organization_model import Organization
from schemas.user_schema import DonorRegisterRequest, UserResponse
from schemas.organization_schema import OrganizationRegisterRequest, OrganizationResponse

router = APIRouter(prefix="/auth", tags=["auth"])

@router.post("/register/donor", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def register_donor(payload: DonorRegisterRequest, db: Session = Depends(get_db)):
    if db.query(User).filter(User.email == payload.email).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    donor_role = db.query(Role).filter(Role.role_name == "Individual Donor").first()
    if donor_role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_user = User(
        first_name=payload.first_name,
        last_name=payload.last_name,
        email=payload.email,
        password_hash=hash_password(payload.password),
        contact_number=payload.contact_number,
        role_id=donor_role.role_id,
        organization_id=None,
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    return new_user


@router.post("/register/organization", response_model=OrganizationResponse, status_code=status.HTTP_201_CREATED)
def register_organization(payload: OrganizationRegisterRequest, db: Session = Depends(get_db)):
    if db.query(User).filter(User.email == payload.contact_email).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")
    if db.query(Organization).filter(Organization.registration_no == payload.registration_no).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Registration number already used")

    org_role = db.query(Role).filter(Role.role_name == "Relief Organization").first()  # [NOT SPECIFIED — confirm exact seeded string]
    if org_role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_org = Organization(
        org_name=payload.org_name,
        organization_type=payload.organization_type,
        address=payload.address,
        contact_person=payload.contact_person,
        registration_no=payload.registration_no,
        contact_email=payload.contact_email,
        legitimacy_document_url=payload.legitimacy_document_url,  # now a real column — this actually persists
    )
    db.add(new_org)
    db.flush()

    new_user = User(
        first_name=payload.contact_person,
        last_name="",  # [NOT SPECIFIED — Capstone 1 doesn't split org contact into first/last name]
        email=payload.contact_email,
        password_hash=hash_password(payload.password),
        contact_number=payload.contact_number,
        role_id=org_role.role_id,
        organization_id=new_org.organization_id,
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_org)
    return new_org