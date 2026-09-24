#!/usr/bin/env python3
"""Oracle verifier (Python side): independently validates the Ruby XAdES signatures.

Reads the JSON bundle from gen_xades.rb on stdin and, for every signed document, verifies
WITHOUT any XAdES library (only lxml + cryptography), replicating what a KSeF-side validator does:

  1. root Reference (URI=""): remove ds:Signature (enveloped transform), exclusive-c14n the
     whole document without comments, SHA-256, compare to DigestValue.
  2. SignedProperties Reference: resolve its URI by Id, check it names xades:SignedProperties,
     exclusive-c14n that element, SHA-256, compare to DigestValue.
  3. SignatureValue: exclusive-c14n SignedInfo, verify against the embedded certificate's
     public key with the declared algorithm. For EC, SignatureValue is R‖S (P1363) -> convert
     to DER for verification (reverse of the gem's DER->P1363), proving the gem emits R‖S, not DER.
  4. SigningCertificate: the embedded certificate is the one that signed, CertDigest is SHA-256
     of its DER, IssuerSerial carries its serial number and issuer DN (RFC 4514, `OID.` prefixes),
     and QualifyingProperties targets the signature.

Exit 0 = all PASS, 1 = any FAIL.
"""
import base64
import hashlib
import json
import re
import sys

from lxml import etree
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.exceptions import InvalidSignature

# Identifiers KSeF accepts (auth/podpis-xades.md). SHA-256 lives in the xmlenc namespace — the
# xmldsig one only defines SHA-1, and an unlisted URI is rejected with code 9105.
SHA256_DIGEST = "http://www.w3.org/2001/04/xmlenc#sha256"
EXC_C14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
ENVELOPED = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
SIGNED_PROPERTIES_TYPE = "http://uri.etsi.org/01903#SignedProperties"

DS = "http://www.w3.org/2000/09/xmldsig#"
XADES = "http://uri.etsi.org/01903/v1.3.2#"
NS = {"ds": DS, "xades": XADES}

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))


def c14n_exclusive(node):
    return etree.tostring(node, method="c14n", exclusive=True, with_comments=False)


def sha256_b64(data):
    return base64.b64encode(hashlib.sha256(data).digest()).decode()


def one(node, path):
    found = node.xpath(path, namespaces=NS)
    return found[0] if len(found) == 1 else None


def name_attributes(name):
    return [[(attr.oid.dotted_string, attr.value) for attr in rdn] for rdn in name.rdns]


def verify_doc(label, xml_str, cert_der):
    root = etree.fromstring(xml_str.encode("utf-8"))
    sig = root.find("ds:Signature", NS)
    check(f"{label}: ds:Signature present", sig is not None)
    if sig is None:
        return

    # --- 0. declared algorithm identifiers (hashing SHA-256 regardless would hide a wrong URI) ---
    digest_algs = set(sig.xpath(".//ds:DigestMethod/@Algorithm", namespaces=NS))
    check(f"{label}: DigestMethod identifiers", digest_algs == {SHA256_DIGEST},
          f"got={sorted(digest_algs)} exp=[{SHA256_DIGEST}]")
    c14n_alg = sig.xpath("ds:SignedInfo/ds:CanonicalizationMethod/@Algorithm", namespaces=NS)[0]
    check(f"{label}: CanonicalizationMethod identifier", c14n_alg == EXC_C14N, f"got={c14n_alg}")
    transforms = set(sig.xpath(".//ds:Transform/@Algorithm", namespaces=NS))
    check(f"{label}: Transform identifiers", transforms == {EXC_C14N, ENVELOPED}, f"got={sorted(transforms)}")

    # --- 1. root reference (enveloped): the whole document, as URI="" means ---
    tree_copy = etree.fromstring(xml_str.encode("utf-8")).getroottree()
    tree_copy.getroot().remove(tree_copy.getroot().find("ds:Signature", NS))
    references = sig.xpath("ds:SignedInfo/ds:Reference", namespaces=NS)
    check(f"{label}: two references", len(references) == 2, f"got={len(references)}")
    root_ref = one(sig, "ds:SignedInfo/ds:Reference[@URI='']")
    root_digest = sha256_b64(c14n_exclusive(tree_copy))
    check(f"{label}: root reference digest",
          root_ref is not None and root_digest == root_ref.find("ds:DigestValue", NS).text,
          f"got={root_digest}")

    # --- 2. SignedProperties reference, resolved by its URI ---
    sp_ref = one(sig, f"ds:SignedInfo/ds:Reference[@Type='{SIGNED_PROPERTIES_TYPE}']")
    uri = sp_ref.get("URI", "") if sp_ref is not None else ""
    target = root.xpath("//*[@Id=$id]", id=uri[1:]) if uri.startswith("#") else []
    signed_props = target[0] if len(target) == 1 else None
    check(f"{label}: SignedProperties reference URI resolves to xades:SignedProperties",
          signed_props is not None and signed_props.tag == f"{{{XADES}}}SignedProperties", f"URI={uri!r}")
    if signed_props is not None:
        sp_digest = sha256_b64(c14n_exclusive(signed_props))
        check(f"{label}: SignedProperties reference digest",
              sp_digest == sp_ref.find("ds:DigestValue", NS).text, f"got={sp_digest}")

    # --- 3. SignatureValue over SignedInfo ---
    signed_info = sig.find("ds:SignedInfo", NS)
    signed_info_c14n = c14n_exclusive(signed_info)
    sig_value = base64.b64decode(sig.find("ds:SignatureValue", NS).text)
    embedded = base64.b64decode(sig.xpath(".//ds:X509Certificate", namespaces=NS)[0].text)
    cert = x509.load_der_x509_certificate(embedded)
    pub = cert.public_key()

    sig_method = sig.xpath("ds:SignedInfo/ds:SignatureMethod/@Algorithm", namespaces=NS)[0]
    try:
        if isinstance(pub, rsa.RSAPublicKey):
            check(f"{label}: SignatureMethod is rsa-sha256", sig_method.endswith("rsa-sha256"))
            pub.verify(sig_value, signed_info_c14n, padding.PKCS1v15(), hashes.SHA256())
        elif isinstance(pub, ec.EllipticCurvePublicKey):
            check(f"{label}: SignatureMethod is ecdsa-sha256", sig_method.endswith("ecdsa-sha256"))
            size = (pub.curve.key_size + 7) // 8
            check(f"{label}: SignatureValue is P1363 R‖S ({2 * size} bytes)", len(sig_value) == 2 * size,
                  f"len={len(sig_value)}")
            r = int.from_bytes(sig_value[:size], "big")
            s = int.from_bytes(sig_value[size:], "big")
            pub.verify(encode_dss_signature(r, s), signed_info_c14n, ec.ECDSA(hashes.SHA256()))
        else:
            check(f"{label}: known key type", False, str(type(pub)))
            return
        check(f"{label}: SignatureValue verifies", True)
    except InvalidSignature:
        check(f"{label}: SignatureValue verifies", False, "InvalidSignature")

    # --- 4. SigningCertificate ---
    check(f"{label}: embedded X509Certificate is the signing certificate", embedded == cert_der)
    qualifying = one(sig, "ds:Object/xades:QualifyingProperties")
    target_ref = qualifying.get("Target") if qualifying is not None else None
    check(f"{label}: QualifyingProperties Target is the signature",
          target_ref is not None and target_ref == f"#{sig.get('Id')}", f"Target={target_ref!r} Id={sig.get('Id')!r}")
    signing_cert = one(sig, ".//xades:SigningCertificate/xades:Cert")
    if signing_cert is None:
        check(f"{label}: one xades:SigningCertificate/xades:Cert", False)
        return
    cert_digest = one(signing_cert, "xades:CertDigest/ds:DigestValue")
    expected_digest = sha256_b64(cert_der)
    check(f"{label}: CertDigest is SHA-256 of the certificate DER",
          cert_digest is not None and cert_digest.text == expected_digest,
          f"got={cert_digest.text if cert_digest is not None else None} exp={expected_digest}")
    serial = one(signing_cert, "xades:IssuerSerial/ds:X509SerialNumber")
    signer = x509.load_der_x509_certificate(cert_der)
    check(f"{label}: X509SerialNumber is the certificate's serial (decimal)",
          serial is not None and re.fullmatch(r"\d+", serial.text or "") and int(serial.text) == signer.serial_number,
          f"got={serial.text if serial is not None else None} exp={signer.serial_number}")
    issuer = one(signing_cert, "xades:IssuerSerial/ds:X509IssuerName")
    text = issuer.text if issuer is not None else ""
    try:
        parsed = x509.Name.from_rfc4514_string(re.sub(r"(?<!\\)(^|,|\+)OID\.(?=\d)", r"\1", text))
        got = name_attributes(parsed)
    except ValueError as e:
        got = f"unparseable: {e}"
    check(f"{label}: X509IssuerName is the certificate's issuer, RDN by RDN",
          got == name_attributes(signer.issuer), f"got={got} exp={name_attributes(signer.issuer)} text={text!r}")


def main():
    bundle = json.load(sys.stdin)
    for document in bundle["documents"]:
        verify_doc(document["label"], document["signed_xml"], base64.b64decode(document["certificate_der_b64"]))

    failed = 0
    for name, ok, detail in results:
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f"  ({detail})" if detail and not ok else ""))
        failed += 0 if ok else 1
    print(f"\n{len(results) - failed}/{len(results)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
