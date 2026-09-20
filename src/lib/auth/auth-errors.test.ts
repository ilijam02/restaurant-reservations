import { describe, expect, it } from "vitest";
import { describeAuthError } from "./auth-errors";

describe("describeAuthError", () => {
  it("says an email is already taken, under the email field", () => {
    for (const code of ["user_already_exists", "email_exists"]) {
      expect(describeAuthError({ code })).toEqual({ field: "email", message: "Nalog sa ovim emailom već postoji." });
    }
  });

  it("explains a rejected address without blaming the format", () => {
    const info = describeAuthError({ code: "email_address_invalid" });
    expect(info?.field).toBe("email");
    expect(info?.message).toMatch(/postoji i da može da prima poštu/);
  });

  it("puts password problems under the password field", () => {
    expect(describeAuthError({ code: "weak_password" })?.field).toBe("password");
    expect(describeAuthError({ code: "same_password" })?.field).toBe("password");
  });

  it("tells the two kinds of rate limit apart, as form-level messages", () => {
    const email = describeAuthError({ code: "over_email_send_rate_limit" });
    const request = describeAuthError({ code: "over_request_rate_limit" });
    expect(email?.field).toBeUndefined();
    expect(email?.message).toMatch(/sat vremena/);
    expect(request?.field).toBeUndefined();
    expect(request?.message).toMatch(/nekoliko minuta/);
  });

  it("treats a bare 429 as a rate limit", () => {
    expect(describeAuthError({ status: 429 })?.message).toMatch(/Previše pokušaja/);
  });

  it("returns null for anything it doesn't know, so the caller can use its own message", () => {
    expect(describeAuthError({ code: "unexpected_failure", status: 500 })).toBeNull();
    expect(describeAuthError({})).toBeNull();
    expect(describeAuthError(null)).toBeNull();
    expect(describeAuthError(undefined)).toBeNull();
  });
});
