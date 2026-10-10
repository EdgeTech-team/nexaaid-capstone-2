import logging

from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from api.v1.health_routes import router as health_router
from api.v1.dashboard_routes import router as dashboard_router
from api.v1.reports import router as report_router
from api.v1.deliveries import router as delivery_router
from api.v1.donation_routes import router as donation_router
from api.v1.receiving_routes import router as receiving_router
from api.v1.session_router import router as session_router
from api.v1.auth_router import router as auth_router
from api.v1.admin_router import router as admin_router
from api.v1.cmo_router import router as cmo_router
from api.v1.logistics_router import router as logistics_router
from api.v1.drrmo_router import router as drrmo_router
from api.v1.lookup_routes import router as lookup_router
from api.v1.upload_routes import router as upload_router
from api.v1.notifications_router import router as notifications_router
from api.v1.contacts import router as contacts_router
from api.v1.public_routes import router as public_router
from api.v1.admin_document_routes import router as admin_document_router
from api.v1.donation_info_routes import router as donation_info_router
from api.v1.account_router import router as account_router
from api.v1.donation_lifecycle_routes import router as donation_lifecycle_router
from api.v1.trips import router as trips_router

app = FastAPI()

@app.exception_handler(RequestValidationError)
async def validation_handler(request: Request, exc: RequestValidationError):
    errors = [{k: v for k, v in e.items() if k not in ("input", "ctx")} for e in exc.errors()]
    print("VALIDATION ERROR:", request.url.path,
          [(e["loc"], e["msg"]) for e in errors], flush=True)
    return JSONResponse(status_code=422, content={"detail": jsonable_encoder(errors)})

# DEV ONLY: turn unexpected crashes into a JSON error the app can show.
# Without this a 500 has no CORS headers, so Chrome hides it and the app
# can only say "cannot reach the server". Registered before CORS so the
# CORS middleware still wraps these responses.
@app.middleware("http")
async def show_server_errors(request: Request, call_next):
    try:
        return await call_next(request)
    except Exception as exc:
        logging.getLogger("uvicorn.error").exception("Unhandled error on %s", request.url.path)
        return JSONResponse(
            status_code=500,
            content={"detail": f"Server error: {type(exc).__name__}: {str(exc).splitlines()[0][:300]}"},
        )


# DEV ONLY: lets the Flutter test app (Chrome / emulator) call the API.
# Tighten allow_origins before deployment.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router)
app.include_router(dashboard_router)
app.include_router(report_router)
app.include_router(delivery_router)
app.include_router(trips_router)
app.include_router(donation_lifecycle_router)   # before donation_router: fixed paths first
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
