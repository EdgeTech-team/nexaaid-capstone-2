"""Copy the uploads saved on THIS machine's disk into upload_blobs
(problema_napud 2.1, "QR image unavailable").

Before migration b4e7c2d9f1a6 every uploaded file lived only on the disk of
the machine that received it, so a barangay QR uploaded on one teammate's
laptop was missing on everyone else's. Run this once on each machine that
has files under UPLOAD_DIR; afterwards every machine on the same database
can show them. (GET /uploads/{file_id} also copies a file in the first time
this machine serves it, so this script only makes that happen right away.)

DRY RUN by default: lists what it would copy and writes nothing.

    cd backend/app
    python scripts/backfill_upload_blobs.py
    python scripts/backfill_upload_blobs.py --apply

Only adds rows; never changes or deletes an upload. Uses DATABASE_URL from
.env, so check where it points. Needs migration b4e7c2d9f1a6 (Mark).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.database import SessionLocal  # noqa: E402
from core.storage import get_storage  # noqa: E402
from models.upload_model import Upload, UploadBlob  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="write the copies")
    args = parser.parse_args()

    db = SessionLocal()
    try:
        shared = {u for (u,) in db.query(UploadBlob.upload_id)}
        copied = elsewhere = 0
        for up in db.query(Upload).order_by(Upload.upload_id):
            if up.upload_id in shared:
                continue
            path = get_storage().path(up.storage_key)
            if not path.exists():
                elsewhere += 1
                continue
            print(f"{'copy' if args.apply else 'would copy'}  {up.file_id}  {up.purpose}  {up.size_bytes} bytes")
            if args.apply:
                db.add(UploadBlob(upload_id=up.upload_id, data=path.read_bytes()))
            copied += 1
        if args.apply:
            db.commit()
        print(
            f"{copied} file(s) {'copied' if args.apply else 'to copy (run again with --apply)'}; "
            f"{elsewhere} not on this machine (run this where they were uploaded)."
        )
    finally:
        db.close()


if __name__ == "__main__":
    main()
