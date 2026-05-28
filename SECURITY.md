<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: SECURITY.md
     Description: Security policy and vulnerability reporting
     License: MIT
     ============================================================================== -->
# Security Policy

We take the security of our project seriously and appreciate your efforts to responsibly disclose any vulnerabilities. This document outlines our security policy and procedures for handling security-related issues.

## Supported Versions

The following table indicates which versions of our project are currently supported with security updates. We highly recommend using a supported version to ensure you receive the latest security patches.

| Version | Supported Status    | Notes                                                    |
| :------ | :------------------ | :------------------------------------------------------- |
| **6.x** | :white_check_mark:  | **Actively maintained and receiving security updates.**  |
| **5.x** | :x: Not Supported   | **End-of-life.** No further security updates will be provided. |
| **4.x** | :x: Not Supported   | **End-of-life.** No further security updates will be provided. |
| **< 4.0** | :x: Not Supported   | **End-of-life.** No further security updates will be provided. |

## Reporting a Vulnerability

We encourage security researchers and users to report any potential security vulnerabilities they discover. Your responsible disclosure helps us keep our project secure for everyone.

**Please follow these steps to report a vulnerability:**

1.  **Do NOT open a public GitHub issue.** This could expose the vulnerability to malicious actors before we have a chance to address it.
2.  **Submit your report via our private security disclosure channel.**
    *   **Option 1 (Recommended): GitHub Security Advisories:** The preferred method is to use GitHub's private vulnerability reporting feature. You can find this option on our repository's "Security" tab.
    *   **Option 2 (Alternative): Email:** If you are unable to use GitHub Security Advisories, please send an email to `armatec0@gmail.com`.
3.  **Provide detailed information:** In your report, please include as much information as possible to help us understand and reproduce the vulnerability. This should ideally include:
    *   A clear description of the vulnerability.
    *   Steps to reproduce the vulnerability.
    *   The affected version(s) of the project.
    *   Any potential impact or exploit scenarios.
    *   If possible, a proof-of-concept (PoC) or exploit code.
    *   Your contact information, so we can communicate with you.

## Our Security Vulnerability Response Process

Upon receiving a vulnerability report, we will follow these steps:

1.  **Acknowledgement (within 2 business days):** We will acknowledge receipt of your report within two business days and provide an initial assessment of the issue.
2.  **Investigation and Triage:** Our security team will investigate the reported vulnerability. This includes validating the report, assessing its severity, and determining the affected components.
3.  **Communication and Updates:** We will keep you informed of our progress throughout the investigation. You can expect updates on the status of your report every 5-7 business days, or more frequently if there are significant developments.
4.  **Remediation:** Once the vulnerability is confirmed, we will work diligently to develop and test a fix. This may involve code changes, configuration updates, or other mitigation strategies.
5.  **Disclosure:**
    *   **Private Disclosure Period:** We will aim for a coordinated disclosure. We request that you keep the vulnerability confidential until we have released a patch and had a reasonable amount of time for users to update.
    *   **Public Disclosure:** Once a fix is available and widely deployed, we will publicly disclose the vulnerability. This typically involves:
        *   Releasing a new version or patch release.
        *   Publishing a GitHub Security Advisory (GHSA) detailing the vulnerability, its impact, and the steps taken to mitigate it.
        *   (Optional) Announcing the vulnerability through our official communication channels (e.g., blog, mailing list, social media).
6.  **Recognition (Optional):** We value the contributions of security researchers. If you wish, and once the vulnerability is publicly disclosed, we would be happy to recognize your efforts in our security advisory.

## Scope of Our Security Policy

This security policy applies to the following:

*   **Repository:** `[Your GitHub Repository URL, e.g., [https://github.com/ArMaTeC/lxc-to-vm](https://github.com/ArMaTeC/lxc-to-vm)]`
*   **Production Systems:** Any publicly accessible services or applications directly operated by us that are part of this project.

Vulnerabilities found in third-party dependencies used by our project should ideally be reported to the respective maintainers of those dependencies. However, if you believe a vulnerability in a dependency has a direct and significant impact on our project, please report it to us, and we will assist in coordinating with the upstream project.

## Security Best Practices for Users

To enhance the security of your own deployments and usage of our project, we recommend the following:

*   **Always use the latest supported version.** Regularly check for new releases and apply security updates promptly.
*   **Follow principle of least privilege.** Grant only the necessary permissions to users and services interacting with our project.
*   **Regularly review your configurations.** Ensure that your environment is configured securely.
*   **Implement strong authentication.** Use strong, unique passwords and consider multi-factor authentication (MFA) where available.
*   **Monitor logs.** Regularly review system and application logs for suspicious activity.

Thank you for helping us make our project more secure.
