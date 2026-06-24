from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Optional
import uuid, datetime

app = FastAPI(title="Notes Service", version="1.0.0")

_notes = {}

class NoteIn(BaseModel):
    title: str
    body: str
    tags: Optional[List[str]] = []

class Note(NoteIn):
    id: str
    created_at: str

@app.get("/health", operation_id="notes_health")
def health():
    return {"status": "ok", "service": "notes-service"}

@app.post("/notes", response_model=Note, operation_id="create_note")
def create_note(note: NoteIn):
    nid = str(uuid.uuid4())[:8]
    obj = Note(id=nid, created_at=datetime.datetime.utcnow().isoformat(), **note.model_dump())
    _notes[nid] = obj
    return obj

@app.get("/notes", response_model=List[Note], operation_id="list_notes")
def list_notes(tag: Optional[str] = None):
    notes = list(_notes.values())
    if tag:
        notes = [n for n in notes if tag in (n.tags or [])]
    return notes

@app.get("/notes/{note_id}", response_model=Note, operation_id="get_note")
def get_note(note_id: str):
    if note_id not in _notes:
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Note not found")
    return _notes[note_id]

@app.delete("/notes/{note_id}", operation_id="delete_note")
def delete_note(note_id: str):
    _notes.pop(note_id, None)
    return {"deleted": note_id}
