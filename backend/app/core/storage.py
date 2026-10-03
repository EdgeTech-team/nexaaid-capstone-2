"""
core/storage.py — where uploaded bytes live.
 
LocalStorage writes under settings.UPLOAD_DIR (default backend/app/var/uploads).
That folder is NEVER mounted as static files: every read goes through
GET /uploads/{file_id}, which does the permission check.
 
To move to cloud storage later (e.g. Cloudflare R2 / S3), write a class
with the same three methods and pass it to set_storage() at startup.
Nothing else in the codebase has to change.
"""

import os
from pathlib import Path
from typing import Optional

from core.config import settings


class LocalStorage:
    def __init__(self,root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key:str) -> Path:
        p = (self.root / key).resolve()
        if self.root not in p.parents: #blocks "../" tricks in a key
            raise ValueError("Invalid storage key")
        return p
    
    def save(self, key:str, data:bytes) -> None:
        p = self._path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, p)  # atomic: a crash never leaves a half-written file
        
    def path(self, key:str) -> Path:
        return self._path(key)
    
    def delete(self, key:str) -> None:
        self._path(key).unlink(missing_ok=True)
        
_storage: Optional[LocalStorage] = None


def get_storage():
        #Created on first use, so importing this module never touches disk
        global _storage
        if _storage is None:
            _storage = LocalStorage(settings.UPLOAD_DIR)
        return _storage
      
def set_storage(backend):
    #Swap the backend (tests use a temp folder). Returns the previous one.
    global _storage
    previous, _storage = _storage, backend
    return previous