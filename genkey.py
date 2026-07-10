"""產生一把新金鑰。用法： python genkey.py [name]"""
import secrets
import sys

name = sys.argv[1] if len(sys.argv) > 1 else "user"
print(f"{name}:sk-{secrets.token_hex(24)}")
