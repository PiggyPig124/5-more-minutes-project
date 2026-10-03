"""Database integrity checks for the SQLite development deployment."""

from sqlalchemy import select

from app.db import initialize_database, make_engine, make_session_factory
from app.models import Account, Conversation, Message


def test_deleting_a_conversation_removes_its_private_messages(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'integrity.db'}")
    initialize_database(engine)
    sessions = make_session_factory(engine)
    with sessions() as db:
        account = Account(email="owner@example.test", display_name="Owner", password_hash="unused")
        db.add(account)
        db.flush()
        conversation = Conversation(owner_id=account.id)
        db.add(conversation)
        db.flush()
        message = Message(conversation_id=conversation.id, sender_id=account.id,
                          role="user", content="private detail", ordinal=1)
        db.add(message)
        db.commit()
        conversation_id, message_id = conversation.id, message.id

    with sessions() as db:
        db.delete(db.get(Conversation, conversation_id))
        db.commit()

    with sessions() as db:
        assert db.scalar(select(Message).where(Message.id == message_id)) is None
    engine.dispose()
