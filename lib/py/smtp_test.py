"""Send a test email. Settings come from environment variables:
SMTP_HOST SMTP_PORT SMTP_SECURITY (ssl|starttls) SMTP_USER SMTP_FROM
SMTP_PASSWORD REPORT_TO. Prints OK or the error, exit status 1 on failure.
"""
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage


def main():
    e = os.environ
    if e.get("HOMEWAN_TEST") == "1":
        print("OK (test mode, nothing sent)")
        return
    msg = EmailMessage()
    msg["Subject"] = "homewan: test email from the installer"
    msg["From"] = e["SMTP_FROM"]
    msg["To"] = e["REPORT_TO"]
    msg.set_content("This is a test from the homewan installer. "
                    "Your weekly report will arrive from this address.")
    ctx = ssl.create_default_context()
    try:
        port = int(e["SMTP_PORT"])
        if e["SMTP_SECURITY"] == "ssl":
            server = smtplib.SMTP_SSL(e["SMTP_HOST"], port, context=ctx, timeout=30)
        else:
            server = smtplib.SMTP(e["SMTP_HOST"], port, timeout=30)
            server.starttls(context=ctx)
        with server:
            server.login(e["SMTP_USER"], e["SMTP_PASSWORD"])
            server.send_message(msg)
    except (OSError, smtplib.SMTPException) as err:
        print(f"FAILED: {err}")
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
