import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from core.shared.health_routes import router as health_router
from core.m9_dashboards.dashboard_routes import router as dashboard_router
from core.m9_dashboards.csws_overview_routes import router as csws_overview_router
from core.m2_disaster_reporting.reports import router as report_router
from core.m8_delivery_tracking.deliveries import router as delivery_router
from core.m4_donation_management.donation_routes import router as donation_router
from core.m5_inventory.pickup_plan_routes import router as pickup_plan_router
from core.m5_inventory.receiving_routes import router as receiving_router
from core.m1_user_management.session_router import router as session_router
from core.m1_user_management.auth_router import router as auth_router
from core.m1_user_management.admin_router import router as admin_router
from core.m6_city_confirmation.cmo_router import router as cmo_router
from core.m7_logistics_support.logistics_router import router as logistics_router
from core.m7_logistics_support.drrmo_router import router as drrmo_router
from core.reference_data.lookup_routes import router as lookup_router
from core.shared.upload_routes import router as upload_router
from core.notifications.notifications_router import router as notifications_router
from core.m2_disaster_reporting.contacts import router as contacts_router
from core.m9_dashboards.public_routes import router as public_router
from core.m1_user_management.admin_document_routes import router as admin_document_router
from core.m4_donation_management.donation_info_routes import router as donation_info_router
from core.m1_user_management.account_router import router as account_router
from core.m4_donation_management.donation_lifecycle_routes import router as donation_lifecycle_router
from core.m8_delivery_tracking.trips import router as trips_router
from core.m8_delivery_tracking.delivery_problems import router as delivery_problems_router
from core.notifications.realtime_router import router as realtime_router
from core.notifications.push_router import router as push_router

from core.shared.config import settings
from core.shared.client_ip import ClientIPMiddleware
from core.m7_logistics_support.delivery_reminders import reminder_loop, reminders_enabled
from core.shared.log_privacy import hide_query_strings_in_access_log

# F-22: the access log keeps method, path and status, not the query string.
hide_query_strings_in_access_log()



def api_docs_settings(app_env: str) -> dict:
    """F-20: /docs, /redoc and /openapi.json only when APP_ENV=development.
    Production corrections call the endpoints directly with an
    Administrator token."""
    dev = app_env == "development"
    return {
        "docs_url": "/docs" if dev else None,
        "redoc_url": "/redoc" if dev else None,
        "openapi_url": "/openapi.json" if dev else None,
    }


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Phase 5: delivery reminders every 5 minutes while the server runs
    (core/m7_logistics_support/delivery_reminders.py). REMINDERS=off turns them off."""
    task = asyncio.create_task(reminder_loop()) if reminders_enabled() else None
    try:
        yield
    finally:
        if task is not None:
            task.cancel()


app = FastAPI(lifespan=lifespan, **api_docs_settings(settings.APP_ENV))

@app.exception_handler(RequestValidationError)
async def validation_handler(request: Request, exc: RequestValidationError):
    errors = [{k: v for k, v in e.items() if k not in ("input", "ctx")} for e in exc.errors()]
    print("VALIDATION ERROR:", request.url.path,
          [(e["loc"], e["msg"]) for e in errors], flush=True)
    return JSONResponse(status_code=422, content={"detail": jsonable_encoder(errors)})

# Convert unexpected crashes into JSON error responses.
# Detailed exception messages are available only in development.
# Production responses use a generic error message.
# CORS middleware wraps these responses.
@app.middleware("http")
async def show_server_errors(request: Request, call_next):
    try:
        return await call_next(request)
    except Exception as exc:
        logging.getLogger("uvicorn.error").exception(
            "Unhandled error on %s", request.url.path
        )

        if settings.APP_ENV == "development":
            lines = str(exc).splitlines()
            error_message = lines[0][:300] if lines else "Unexpected error"
            detail = f"Server error: {type(exc).__name__}: {error_message}"
        else:
            detail = "Internal server error"

        return JSONResponse(
            status_code=500,
            content={"detail": detail},
        )

@app.get("/")
def root():
    return {"status": "ok", "service": "NexaAid API"}


app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://nexaaid1.netlify.app",
    ],
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    # F-20: no cookies anywhere; the app sends a Bearer token.
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    # NF-003: paged lists send their total in this header; without it the
    # web build cannot read it (browsers hide non-simple headers).
    expose_headers=["X-Total-Count"],
)

app.include_router(health_router)
app.include_router(dashboard_router)
app.include_router(csws_overview_router)   # CSWS dashboard detail pages (Nov 23)
app.include_router(report_router)
app.include_router(delivery_router)
app.include_router(trips_router)
app.include_router(delivery_problems_router)   # reschedule / return / cancel
app.include_router(donation_lifecycle_router)   # before donation_router: fixed paths first
app.include_router(pickup_plan_router)          # Door to Door pickup plan (Oct 12 pickup logic v2)
app.include_router(donation_router)
app.include_router(receiving_router)
app.include_router(session_router)
app.include_router(auth_router)
app.include_router(admin_router)
app.include_router(cmo_router)
app.include_router(logistics_router)
app.include_router(drrmo_router)
app.include_router(lookup_router)
app.include_router(upload_router)
app.include_router(notifications_router)
app.include_router(public_router)
app.include_router(admin_document_router)
app.include_router(donation_info_router)
app.include_router(contacts_router)
app.include_router(account_router)
app.include_router(realtime_router)      # GET /ws live updates (core/notifications/realtime.py)
app.include_router(push_router)          # GET /push/topic, Android push (core/notifications/push.py)

# F-21: the real client address behind Render's proxy (core/shared/client_ip.py).
# Added last, so it runs first.
app.add_middleware(ClientIPMiddleware)
