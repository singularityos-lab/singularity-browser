import hashlib, hmac, os, sys
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import serialization


def hkdf(ikm, salt, length, info=b""):
    prk = hmac.new(salt or b"\0" * 32, ikm, hashlib.sha256).digest()
    out, block, i = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([i]), hashlib.sha256).digest()
        out += block
        i += 1
    return out[:length]


class Noise:
    def __init__(self, name):
        self.ck = name.encode().ljust(32, b"\0")
        self.h = self.ck
        self.k = None
        self.n = 0

    def mix_hash(self, data):
        self.h = hashlib.sha256(self.h + data).digest()

    def mix_key(self, ikm):
        out = hkdf(ikm, self.ck, 64)
        self.ck, self.k, self.n = out[:32], out[32:], 0

    def mix_key_and_hash(self, ikm):
        out = hkdf(ikm, self.ck, 96)
        self.ck = out[:32]
        self.mix_hash(out[32:64])
        self.k, self.n = out[64:], 0

    def nonce(self):
        return self.n.to_bytes(4, "big") + b"\0" * 8

    def encrypt_and_hash(self, plain):
        ct = AESGCM(self.k).encrypt(self.nonce(), plain, self.h)
        self.n += 1
        self.mix_hash(ct)
        return ct

    def decrypt_and_hash(self, ct):
        plain = AESGCM(self.k).decrypt(self.nonce(), ct, self.h)
        self.n += 1
        self.mix_hash(ct)
        return plain


def point(key):
    return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def ecdh(priv, pub):
    return priv.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pub))


class Crypter:
    def __init__(self, read, write):
        self.read, self.write, self.rs, self.ws = read, write, 0, 0

    def encrypt(self, msg):
        size = (len(msg) + 1 + 31) & ~31
        padded = msg + b"\0" * (size - len(msg) - 1) + bytes([size - len(msg) - 1])
        ct = AESGCM(self.write).encrypt(b"\0" * 8 + self.ws.to_bytes(4, "big"), padded, b"")
        self.ws += 1
        return ct

    def decrypt(self, ct):
        p = AESGCM(self.read).decrypt(b"\0" * 8 + self.rs.to_bytes(4, "big"), ct, b"")
        self.rs += 1
        return p[: len(p) - p[-1] - 1]


def main():
    psk = bytes.fromhex(sys.stdin.readline().strip())
    initiator = bytes.fromhex(sys.stdin.readline().strip())
    msg = bytes.fromhex(sys.stdin.readline().strip())
    noise = Noise("Noise_KNpsk0_P256_AESGCM_SHA256")
    noise.mix_hash(b"\x01")
    noise.mix_hash(initiator)
    noise.mix_key_and_hash(psk)
    e = msg[:65]
    noise.mix_hash(e)
    noise.mix_key(e)
    assert noise.decrypt_and_hash(msg[65:]) == b""
    mine = ec.generate_private_key(ec.SECP256R1())
    mine_pub = point(mine)
    noise.mix_hash(mine_pub)
    noise.mix_key(mine_pub)
    noise.mix_key(ecdh(mine, e))
    noise.mix_key(ecdh(mine, initiator))
    response = mine_pub + noise.encrypt_and_hash(b"")
    k = hkdf(b"", noise.ck, 64)
    crypter = Crypter(read=k[:32], write=k[32:])
    print(response.hex(), flush=True)
    print(crypter.encrypt(bytes.fromhex("a10143a10102")).hex(), flush=True)
    command = crypter.decrypt(bytes.fromhex(sys.stdin.readline().strip()))
    print(command.hex(), file=sys.stderr, flush=True)
    print(crypter.encrypt(b"\x01\x00" + bytes.fromhex("a1016464656d6f")).hex(), flush=True)


main()
