# routers/auth_router.py
from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import hash_password
from core.database import get_db
from core.uploads import claim_registration_files, file_url
from models.user_rbac_model import User
from models.role_model import Role
from models.organization_model import Organization
from schemas.user_schema import DonorRegisterRequest, UserResponse
from schemas.organization_schema import OrganizationRegisterRequest, OrganizationResponse
from core.notifications import notify_event_many, user_ids_with_role

router = APIRouter(prefix="/auth", tags=["auth"])

# Both endpoints never call db.commit() themselves: get_db commits once at
# the end, and rolls back if anything raised. So when an uploaded file
# can't be claimed (expired, wrong token, wrong purpose), the account is
# not created either.


def _email_taken(db: Session, email: str) -> bool:
    return db.query(User).filter(func.lower(User.email) == email.lower()).first() is not None


def _flush_or_409(db: Session, detail: str) -> None:
    # Two people registering the same email at the same moment: the second
    # one hits the UNIQUE constraint here instead of a 500.
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)


@router.post("/register/donor", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def register_donor(payload: DonorRegisterRequest, request: Request, db: Session = Depends(get_db)):
    """UC-D1 Register Individual Donor (adviser item 2)."""
    if _email_taken(db, payload.email):
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
        id_type=payload.id_type,
        role_id=donor_role.role_id,
        organization_id=None,
    )
    db.add(new_user)
    _flush_or_409(db, "Email already registered")

    # UC-D1 step 3: attach the ID photos uploaded before the account existed.
    files = claim_registration_files(db, new_user, {
        "id_front": payload.id_front,
        "id_back": payload.id_back,
    })
    # The back is found later through the uploads table (owner + purpose).
    new_user.id_document_url = file_url(files["id_front"].file_id)

    log_action(db, new_user, "REGISTER DONOR", "users", new_user.user_id, new={
        "email": new_user.email,
        "id_type": new_user.id_type,
        "consent_ra10173": True,
    }, request=request)
    db.flush()
    db.refresh(new_user)
    return new_user


@router.post("/register/organization", response_model=OrganizationResponse, status_code=status.HTTP_201_CREATED)
def register_organization(payload: OrganizationRegisterRequest, request: Request, db: Session = Depends(get_db)):
    """UC-A2: the organization registers and waits as Pending for the
    Administrator's review (adviser item 2.1)."""
    if _email_taken(db, payload.contact_email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")
    if db.query(Organization).filter(Organization.registration_no == payload.registration_no).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Registration number already used")

    org_role = db.query(Role).filter(Role.role_name == "Relief Organization").first()
    if org_role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_org = Organization(
        org_name=payload.org_name,
        organization_type=payload.organization_type_label,
        address=payload.address,
        contact_person=payload.contact_person,
        registration_no=payload.registration_no,
        contact_email=payload.contact_email,
    )
    db.add(new_org)
    _flush_or_409(db, "Email or registration number already exists")

    new_user = User(
        first_name=payload.contact_first_name,
        last_name=payload.contact_last_name,
        email=payload.contact_email,
        password_hash=hash_password(payload.password),
        contact_number=payload.contact_number,
        role_id=org_role.role_id,
        organization_id=new_org.organization_id,
    )
    db.add(new_user)
    _flush_or_409(db, "Email already registered")

    # UC-A2 step 4: the supporting document the Administrator reviews.
    files = claim_registration_files(db, new_user, {
        "legitimacy_document": payload.legitimacy_document,
    })
    new_org.legitimacy_document_url = file_url(files["legitimacy_document"].file_id)

    log_action(db, new_user, "REGISTER ORGANIZATION", "organizations", new_org.organization_id, new={
        "org_name": new_org.org_name,
        "email": new_user.email,
        "consent_ra10173": True,
    }, request=request)

    notify_event_many(db, user_ids_with_role(db, ["Administrator"]),
                      "org_registered", "organization", new_org.organization_id,
                      name=new_org.org_name)
    # Login stays blocked by authenticate_user() until the admin approves the org.
    db.flush()
    db.refresh(new_org)
    return new_org
