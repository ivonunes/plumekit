import Testing
import Foundation
import Crypto
@testable import PlumeAWS

// AWS SigV4 verified OFFLINE against the canonical aws4 test-suite "get-vanilla"
// vector — so the signer is proven correct without needing live AWS. (The same
// signer drives S3, SQS, SSM.)
//
// Vector (AWS docs / aws4_testsuite):
//   credentials AKIDEXAMPLE / wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY
//   region us-east-1, service "service", date 20150830T123600Z
//   GET / with headers host:example.amazonaws.com, x-amz-date:20150830T123600Z
//   → Signature 5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31
@Test func sigV4MatchesAWSGetVanillaVector() {
    let signer = SigV4(region: "us-east-1", service: "service",
                       accessKey: "AKIDEXAMPLE",
                       secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    let emptyHash = SigV4.payloadHash(Data())
    #expect(emptyHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    let auth = signer.authorization(
        method: "GET", canonicalURI: "/", canonicalQuery: "",
        headers: [("host", "example.amazonaws.com"), ("x-amz-date", "20150830T123600Z")],
        payloadHash: emptyHash, amzDate: "20150830T123600Z", dateStamp: "20150830")

    #expect(auth == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
}

// Header ordering must not matter — the signer sorts/lowercases internally, so the
// signature is identical regardless of the order the caller passes headers.
@Test func sigV4SortsHeadersDeterministically() {
    let signer = SigV4(region: "us-east-1", service: "service",
                       accessKey: "AKIDEXAMPLE",
                       secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    let hash = SigV4.payloadHash(Data())
    let a = signer.authorization(method: "GET", canonicalURI: "/", canonicalQuery: "",
        headers: [("host", "example.amazonaws.com"), ("x-amz-date", "20150830T123600Z")],
        payloadHash: hash, amzDate: "20150830T123600Z", dateStamp: "20150830")
    let b = signer.authorization(method: "GET", canonicalURI: "/", canonicalQuery: "",
        headers: [("X-Amz-Date", "20150830T123600Z"), ("Host", "example.amazonaws.com")],
        payloadHash: hash, amzDate: "20150830T123600Z", dateStamp: "20150830")
    #expect(a == b)
}
