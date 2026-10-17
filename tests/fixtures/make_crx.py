import hashlib, io, os, struct, subprocess, sys, tempfile, zipfile

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)

def field(number, payload):
    return varint(number << 3 | 2) + varint(len(payload)) + payload

source, output = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(output))) as work:
    key = os.path.join(work, "key.pem")
    subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True, capture_output=True)
    public = subprocess.run(["openssl", "rsa", "-in", key, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for base, dirs, files in sorted(os.walk(source)):
            for name in sorted(files):
                full = os.path.join(base, name)
                z.write(full, os.path.relpath(full, source))
    archive = archive.getvalue()
    crx_id = hashlib.sha256(public).digest()[:16]
    signed = field(1, crx_id)
    message = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed)) + signed + archive
    data = os.path.join(work, "data")
    with open(data, "wb") as f:
        f.write(message)
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, data], check=True, capture_output=True).stdout
    header = field(2, field(1, public) + field(2, signature)) + field(10000, signed)
    with open(output, "wb") as f:
        f.write(b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive)
    print("".join(chr(ord("a") + (b >> 4)) + chr(ord("a") + (b & 15)) for b in crx_id))
