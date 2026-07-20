/**
 * ToolingApiHealthCheck
 *
 * Setup-only utility called by metaMapperApp on mount to verify that the
 * MetaMapper_Tooling_API Named Credential is reachable and the current user
 * is authorized. Returns a typed result so the LWC can render one of five
 * distinct failure states without parsing exception messages.
 *
 * Must NOT be called from DependencyQueueable or any async context - it makes
 * a synchronous callout that counts against the per-transaction callout limit.
 * Invoked exclusively from the @AuraEnabled controller boundary.
 */
public with sharing class ToolingApiHealthCheck {
  // Bypasses the custom permission check in unit tests (tests cannot assign custom
  // permissions to a synthetic user without a full org setup). Never set to true in
  // production code; only toggled by ToolingApiHealthCheckTest.
  @TestVisible
  private static Boolean skipPermissionCheck = false;

  public enum HealthStatus {
    AUTHORIZED,
    UNAUTHORIZED, // HTTP 401 - Named Credential not authorized by current user
    PERMISSION_SET_MISSING, // Custom Permission 'MetaMapper_Application_Access' not assigned
    CALLOUT_FORBIDDEN, // HTTP 403 - Connected App OAuth scope misconfigured
    UNREACHABLE, // HTTP 5xx - transient org issue
    TIMEOUT // CalloutException with read timeout
  }

  public class HealthResult {
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String message;

    public HealthResult(HealthStatus s, String msg) {
      this.status = s.name();
      this.message = msg;
    }
  }

  /**
   * Issues a minimal Tooling API query via Named Credential to confirm reachability
   * and authorization. Called once on LWC mount; result drives the pre-flight UI state.
   *
   * @return HealthResult with status AUTHORIZED, UNAUTHORIZED, PERMISSION_SET_MISSING,
   *         CALLOUT_FORBIDDEN, UNREACHABLE, or TIMEOUT
   */
  @AuraEnabled(cacheable=false)
  public static HealthResult verify() {
    // Permission guard: check before making any callout.
    // Unauthorized users must never trigger a Named Credential network call.
    if (
      !skipPermissionCheck &&
      !FeatureManagement.checkPermission('MetaMapper_Application_Access')
    ) {
      return new HealthResult(
        HealthStatus.PERMISSION_SET_MISSING,
        'You don\'t have access to MetaMapper. Ask your admin to assign you the ' +
          'MetaMapper Admin permission set. If you were recently assigned, try refreshing ' +
          'your browser - Salesforce caches permission checks for a few minutes.'
      );
    }
    try {
      HttpRequest req = new HttpRequest();
      req.setEndpoint(
        'callout:MetaMapper_Tooling_API/services/data/v66.0/tooling/query/' +
        '?q=SELECT+Id+FROM+Organization+LIMIT+1'
      );
      req.setMethod('GET');
      req.setTimeout(10000);

      HttpResponse res = new Http().send(req);
      Integer code = res.getStatusCode();

      if (code == 200) {
        return new HealthResult(HealthStatus.AUTHORIZED, null);
      }
      if (code == 401) {
        return new HealthResult(
          HealthStatus.UNAUTHORIZED,
          'MetaMapper needs one-time setup. An admin must authorize the Tooling API connection.'
        );
      }
      if (code == 403) {
        return new HealthResult(
          HealthStatus.CALLOUT_FORBIDDEN,
          'MetaMapper connected but was denied by the Tooling API. Ask your admin to verify ' +
          'the Connected App has the required OAuth scopes.'
        );
      }
      return new HealthResult(
        HealthStatus.UNREACHABLE,
        'MetaMapper cannot reach the Tooling API right now. This may be a temporary org issue.'
      );
    } catch (System.CalloutException e) {
      if (
        e.getMessage() != null && e.getMessage().containsIgnoreCase('timed out')
      ) {
        return new HealthResult(
          HealthStatus.TIMEOUT,
          'MetaMapper\'s connection check timed out. This is usually a temporary org issue - try again in a moment.'
        );
      }
      return new HealthResult(
        HealthStatus.UNREACHABLE,
        'MetaMapper cannot reach the Tooling API right now. This may be a temporary org issue.'
      );
    }
  }
}
