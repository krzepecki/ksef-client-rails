#!/usr/bin/env python3
"""Oracle verifier (Python side): independently checks the Ruby crypto bundle.

Reads the JSON bundle produced by gen_crypto.rb on stdin and verifies, using the
`cryptography` library as an independent implementation:

  * AES-256-CBC decrypts to the original plaintext using ONLY key + IV (no IV prefix)
    -> confirms there is no IV prefix.
  * ciphertext length == plaintext padded to the AES block (i.e. NO extra 16 bytes of IV).
  * RSA-OAEP(SHA-256, MGF1-SHA256) ciphertext decrypts with the private key.
  * the encrypted KSeF token decrypts to exactly "<token>|<timestampMs>", with the
    KsefTokenEncryption key.
  * SHA-256 base64 + size match.
  * CSR (RSA and EC) parse, signatures verify, and the subject has one attribute per RDN, in
    the C# CreateSubjectDistinguishedName order, with its ASN.1 string type (read from the DER).

Exit code 0 = all PASS, 1 = any FAIL.
"""
import base64
import json
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives import padding as sympad
from cryptography import x509
import hashlib

# C# CreateSubjectDistinguishedName: RDN order, OID and ASN.1 string type of each enrollment field.
UTF8_STRING = 0x0C
PRINTABLE_STRING = 0x13
SUBJECT_ORDER = [
    ("commonName", "2.5.4.3", UTF8_STRING),
    ("surname", "2.5.4.4", UTF8_STRING),
    ("givenName", "2.5.4.42", UTF8_STRING),
    ("organizationName", "2.5.4.10", UTF8_STRING),
    ("organizationIdentifier", "2.5.4.97", UTF8_STRING),
    ("countryName", "2.5.4.6", PRINTABLE_STRING),
    ("serialNumber", "2.5.4.5", PRINTABLE_STRING),
    ("uniqueIdentifier", "2.5.4.45", UTF8_STRING),
]
TAG_NAMES = {UTF8_STRING: "UTF8String", PRINTABLE_STRING: "PrintableString"}

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))


def b64(s):
    return base64.b64decode(s)


def oaep_decrypt(private_key_pem, ciphertext):
    priv = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    return priv.decrypt(ciphertext, padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),
                                                 algorithm=hashes.SHA256(), label=None))


def verify_aes(a):
    key, iv = b64(a["key_b64"]), b64(a["iv_b64"])
    ct, pt = b64(a["ciphertext_b64"]), b64(a["plaintext_b64"])
    dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = dec.update(ct) + dec.finalize()
    unpad = sympad.PKCS7(128).unpadder()
    plain = unpad.update(padded) + unpad.finalize()
    check("AES-256-CBC decrypt (key+IV only, no prefix)", plain == pt)
    # If Ruby had prefixed the IV, ciphertext would be 16 bytes longer than the padded plaintext.
    expected_len = (len(pt) // 16 + 1) * 16
    check("AES ciphertext has NO IV prefix (len check)", len(ct) == expected_len,
          f"ct={len(ct)} expected={expected_len}")


def verify_rsa(r):
    dec = oaep_decrypt(r["private_key_pem"], b64(r["ciphertext_b64"]))
    check("RSA-OAEP-SHA256/MGF1 decrypt", dec == b64(r["plaintext_b64"]))


def verify_ksef_token(t):
    # The expected plaintext is built here from the inputs, not taken from the Ruby side.
    expected = f"{t['token']}|{int(t['timestamp_ms'])}".encode()
    check("KSeF token: encrypted with the KsefTokenEncryption key",
          t["usages_asked"] == ["KsefTokenEncryption"], f"asked={t['usages_asked']}")
    check("KSeF token: publicKeyId of that key", t["public_key_id"] == "token-key-id", t["public_key_id"])
    try:
        plain = oaep_decrypt(t["private_key_pem"], b64(t["encrypted_token_b64"]))
    except ValueError as e:
        check("KSeF token: RSA-OAEP-SHA256/MGF1 decrypt", False, str(e))
        return
    check('KSeF token: plaintext is exactly "token|timestampMs"', plain == expected,
          f"got={plain!r} exp={expected!r}")


def verify_metadata(m, a):
    pt = b64(a["plaintext_b64"])
    digest = base64.b64encode(hashlib.sha256(pt).digest()).decode()
    check("SHA-256 base64 matches", digest == m["hash_sha_b64"])
    check("file size matches", len(pt) == m["size"])


def der_items(data):
    """Splits DER bytes into (tag, content) pairs (definite lengths)."""
    items, i = [], 0
    while i < len(data):
        tag, length = data[i], data[i + 1]
        i += 2
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(data[i:i + count], "big")
            i += count
        items.append((tag, data[i:i + length]))
        i += length
    return items


def decode_oid(content):
    arcs, value = [], 0
    for byte in content:
        value = (value << 7) | (byte & 0x7F)
        if not byte & 0x80:
            arcs.append(value)
            value = 0
    first = min(arcs[0] // 40, 2)
    return ".".join(str(arc) for arc in [first, arcs[0] - 40 * first] + arcs[1:])


def subject_rdns(csr):
    """[(attributes per RDN, oid, ASN.1 tag, value)] straight from CertificationRequestInfo.subject."""
    ((_, info),) = der_items(csr.tbs_certrequest_bytes)
    _, subject = der_items(info)[1]
    rdns = []
    for _, rdn in der_items(subject):
        attributes = der_items(rdn)
        (_, oid), (tag, value) = der_items(attributes[0][1])
        rdns.append((len(attributes), decode_oid(oid), tag, value.decode("utf-8")))
    return rdns


def verify_csr(entry):
    label, data = entry["label"], entry["subject"]
    csr = x509.load_der_x509_csr(b64(entry["der_b64"]))
    check(f"{label} signature valid", csr.is_signature_valid)
    got = subject_rdns(csr)
    expected = [(1, oid, tag, data[field]) for field, oid, tag in SUBJECT_ORDER if data.get(field)]
    check(f"{label} subject: one attribute per RDN", all(count == 1 for count, *_ in got),
          f"counts={[count for count, *_ in got]}")
    check(f"{label} subject DN matches (C# order + values)",
          [(oid, value) for _, oid, _, value in got] == [(oid, value) for _, oid, _, value in expected],
          f"got={[(oid, value) for _, oid, _, value in got]}")
    check(f"{label} subject ASN.1 string types (PrintableString for C and serialNumber)",
          [(oid, tag) for _, oid, tag, _ in got] == [(oid, tag) for _, oid, tag, _ in expected],
          f"got={[(oid, TAG_NAMES.get(tag, hex(tag))) for _, oid, tag, _ in got]}")
    check(f"{label} subject equals what cryptography parses",
          [(a.oid.dotted_string, a.value) for a in csr.subject] == [(oid, value) for _, oid, _, value in got])


def main():
    bundle = json.load(sys.stdin)
    verify_aes(bundle["aes"])
    verify_rsa(bundle["rsa_oaep"])
    verify_ksef_token(bundle["ksef_token"])
    verify_metadata(bundle["metadata"], bundle["aes"])
    for entry in bundle["csrs"]:
        verify_csr(entry)

    failed = 0
    for name, ok, detail in results:
        status = "PASS" if ok else "FAIL"
        line = f"[{status}] {name}"
        if detail and not ok:
            line += f"  ({detail})"
        print(line)
        if not ok:
            failed += 1
    print(f"\n{len(results) - failed}/{len(results)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
