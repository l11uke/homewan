"""Sending email through the SMTP server chosen in the installer."""
import os
import smtplib
import ssl
from email.message import EmailMessage
from email.utils import formatdate, make_msgid


def build(settings, subject, text, html, attachments=()):
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = settings.get("SMTP_FROM")
    msg["To"] = ", ".join(settings.report_to)
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="homewan.local")
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    for path in attachments:
        with open(path, "rb") as f:
            msg.add_attachment(f.read(), maintype="image", subtype="png", filename=os.path.basename(path))
    return msg


def send(settings, msg):
    host, port = settings.get("SMTP_HOST"), int(settings.get("SMTP_PORT", "465"))
    ctx = ssl.create_default_context()
    if settings.get("SMTP_SECURITY") == "starttls":
        server = smtplib.SMTP(host, port, timeout=60)
        server.starttls(context=ctx)
    else:
        server = smtplib.SMTP_SSL(host, port, context=ctx, timeout=60)
    with server:
        server.login(settings.get("SMTP_USER"), os.environ.get("SMTP_PASSWORD", ""))
        server.send_message(msg)


def save(msg, path):
    with open(path, "wb") as f:
        f.write(bytes(msg))
