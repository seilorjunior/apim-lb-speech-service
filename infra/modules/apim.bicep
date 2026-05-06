// =====================================================================
// modules/apim.bicep
// Azure API Management (Basic v2) with:
//   * System-assigned Managed Identity (used to call Speech)
//   * Two single backends (one per Speech account)
//   * One pool backend (round-robin load balancer)
//   * One API "speech-stt" exposing the Fast Transcription endpoint
//   * Operation policy: route to pool, auth via MI, retry 429/5xx
//   * App Insights logger + diagnostic
//
// Backend pool / load-balanced backends are GA on Basic v2 and above
// (API Management API version 2023-09-01-preview+, GA in 2024-05-01).
// =====================================================================
param apimName string
param location string
param tags object

@description('Email address used as the publisher of the API Management instance.')
param publisherEmail string
param publisherName string

@description('Application Insights resource ID (for diagnostic settings / loggers).')
param appInsightsId string

@description('Application Insights connection string (consumed by the APIM logger).')
@secure()
param appInsightsConnectionString string

@description('Endpoint URL of the primary Speech account (custom subdomain).')
param speechPrimaryEndpoint string

@description('Endpoint URL of the secondary Speech account (custom subdomain).')
param speechSecondaryEndpoint string

@description('Resource name of the primary Speech account (used as the backend id).')
param speechPrimaryName string

@description('Resource name of the secondary Speech account (used as the backend id).')
param speechSecondaryName string

@description('Name of the Azure Managed Redis cluster used as the APIM external cache. Empty string disables the external cache (APIM falls back to its built-in cache, which is sufficient for a single-unit BasicV2 deployment).')
param redisClusterName string = ''

@description('Name of the database under the AMR cluster (always "default" for redisEnterprise). Ignored when redisClusterName is empty.')
param redisDatabaseName string = 'default'

// External cache is enabled only when a cluster name is supplied.
var useExternalCache = !empty(redisClusterName)

// Strip trailing slash from Speech endpoints (APIM backend URLs must not end with "/").
#disable-next-line BCP329
var speechPrimaryUrl = endsWith(speechPrimaryEndpoint, '/') ? substring(speechPrimaryEndpoint, 0, length(speechPrimaryEndpoint) - 1) : speechPrimaryEndpoint
#disable-next-line BCP329
var speechSecondaryUrl = endsWith(speechSecondaryEndpoint, '/') ? substring(speechSecondaryEndpoint, 0, length(speechSecondaryEndpoint) - 1) : speechSecondaryEndpoint

// Hostnames (used by the submit policy to identify which backend handled a POST).
var speechPrimaryHost = replace(replace(speechPrimaryUrl, 'https://', ''), '/', '')
var speechSecondaryHost = replace(replace(speechSecondaryUrl, 'https://', ''), '/', '')
var backendPrimaryName = 'speech-${speechPrimaryName}'
var backendSecondaryName = 'speech-${speechSecondaryName}'

// ---------- APIM service ----------
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
    customProperties: {
      // Enforce TLS 1.2 client connections
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
    }
  }
}

// ---------- Existing AMR references (used to build the cache connection string) ----------
// Both `existing` references and the cache resource are gated on `useExternalCache`
// so the module deploys cleanly when the AMR module is skipped.
resource redisCluster 'Microsoft.Cache/redisEnterprise@2025-04-01' existing = if (useExternalCache) {
  name: redisClusterName
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' existing = if (useExternalCache) {
  parent: redisCluster
  name: redisDatabaseName
}

// ---------- External cache: APIM -> Azure Managed Redis (optional) ----------
// APIM looks up an external cache when policies use cache-store-value /
// cache-lookup-value with caching-type="external" or "prefer-external".
// With caching-type="prefer-external" (used by submit/stateful policies),
// APIM falls back to its built-in cache when no external cache is registered,
// so this resource is purely an opt-in scale-out feature.
//   https://learn.microsoft.com/azure/api-management/api-management-howto-cache-external
// AMR uses port 10000 and TLS-only (Encrypted protocol) by default.
#disable-next-line use-secure-value-for-secure-inputs
resource externalRedisCache 'Microsoft.ApiManagement/service/caches@2024-05-01' = if (useExternalCache) {
  parent: apim
  name: 'redis'
  properties: {
    description: 'Azure Managed Redis (jobId -> backend pinning)'
    useFromLocation: 'default'
    connectionString: '${redisCluster!.properties.hostName}:10000,password=${redisDatabase!.listKeys().primaryKey},ssl=True,abortConnect=False'
    resourceId: '${environment().resourceManager}${substring(redisCluster!.id, 1)}'
  }
}

// ---------- Single backends (one per Speech account) ----------
resource backendPrimary 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendPrimaryName
  properties: {
    description: 'Speech (primary region)'
    type: 'Single'
    protocol: 'http'
    url: speechPrimaryUrl
    circuitBreaker: {
      rules: [
        {
          name: 'breakOn5xxAnd429'
          failureCondition: {
            count: 5
            interval: 'PT1M'
            statusCodeRanges: [
              { min: 429, max: 429 }
              { min: 500, max: 599 }
            ]
          }
          tripDuration: 'PT30S'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource backendSecondary 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendSecondaryName
  properties: {
    description: 'Speech (secondary region)'
    type: 'Single'
    protocol: 'http'
    url: speechSecondaryUrl
    circuitBreaker: {
      rules: [
        {
          name: 'breakOn5xxAnd429'
          failureCondition: {
            count: 5
            interval: 'PT1M'
            statusCodeRanges: [
              { min: 429, max: 429 }
              { min: 500, max: 599 }
            ]
          }
          tripDuration: 'PT30S'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

// ---------- Backend pool (load balancer) ----------
// Equal weight + equal priority across the two backends => round-robin.
resource backendPool 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'speech-pool'
  properties: {
    description: 'Round-robin pool across primary + secondary Speech accounts'
    type: 'Pool'
    pool: {
      services: [
        {
          id: '/backends/${backendPrimary.name}'
          priority: 1
          weight: 1
        }
        {
          id: '/backends/${backendSecondary.name}'
          priority: 1
          weight: 1
        }
      ]
    }
  }
}

// ---------- API: speech-stt ----------
// Path: /speech  (e.g. https://<apim>.azure-api.net/speech/...)
// SubscriptionRequired: false (dev-only, per user choice).
resource speechApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'speech-stt'
  properties: {
    displayName: 'Speech-to-Text (load balanced)'
    path: 'speech'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    // serviceUrl is overridden by set-backend-service in the policy.
    serviceUrl: speechPrimaryUrl
  }
}

// Operation: POST /speechtotext/transcriptions:transcribe   (Fast Transcription API)
resource fastTranscribeOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'fast-transcribe'
  properties: {
    displayName: 'Fast Transcription'
    method: 'POST'
    urlTemplate: '/speechtotext/transcriptions:transcribe'
    description: 'Synchronous batch transcription (Fast Transcription) routed via APIM round-robin pool.'
  }
}

// Operation: GET /speechtotext/v3.2/transcriptions     (list / health)
resource listTranscriptionsOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'list-transcriptions'
  properties: {
    displayName: 'List transcriptions (v3.2)'
    method: 'GET'
    urlTemplate: '/speechtotext/v3.2/transcriptions'
  }
}

// ---------- Operation policy: pool + MI auth + retry ----------
var operationPolicyXml = '''
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="speech-pool" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
  </inbound>
  <backend>
    <retry condition="@(context.Response.StatusCode == 429 || context.Response.StatusCode >= 500)"
           count="3" interval="1" delta="1" max-interval="10" first-fast-retry="false">
      <forward-request buffer-request-body="true" />
    </retry>
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''

resource fastTranscribePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: fastTranscribeOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: operationPolicyXml
  }
  dependsOn: [
    backendPool
  ]
}

resource listTranscriptionsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: listTranscriptionsOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: operationPolicyXml
  }
  dependsOn: [
    backendPool
  ]
}

// =====================================================================
// Batch transcription operations (stateful — require backend pinning).
// Strategy:
//   1. POST /transcriptions  → goes to the round-robin pool.
//      Submit policy parses the Location header, identifies which
//      backend handled the request, caches jobId -> backend-id for 24h,
//      then rewrites Location/body so the client sees APIM URLs.
//   2. GET / DELETE /transcriptions/{jobId}[/files]  → looks up the
//      cache by jobId and pins to the recorded backend (falls back to
//      the pool if cache miss — which only happens after TTL expires).
// =====================================================================

resource submitBatchOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'submit-batch-transcription'
  properties: {
    displayName: 'Submit batch transcription (v3.2)'
    method: 'POST'
    urlTemplate: '/speechtotext/v3.2/transcriptions'
    description: 'Create a batch transcription job. APIM caches jobId -> backend so subsequent polls hit the same Speech account.'
  }
}

resource getBatchOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'get-batch-transcription'
  properties: {
    displayName: 'Get batch transcription status (v3.2)'
    method: 'GET'
    urlTemplate: '/speechtotext/v3.2/transcriptions/{jobId}'
    templateParameters: [
      {
        name: 'jobId'
        type: 'string'
        required: true
      }
    ]
  }
}

resource getBatchFilesOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'get-batch-files'
  properties: {
    displayName: 'Get batch transcription files (v3.2)'
    method: 'GET'
    urlTemplate: '/speechtotext/v3.2/transcriptions/{jobId}/files'
    templateParameters: [
      {
        name: 'jobId'
        type: 'string'
        required: true
      }
    ]
  }
}

resource deleteBatchOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'delete-batch-transcription'
  properties: {
    displayName: 'Delete batch transcription (v3.2)'
    method: 'DELETE'
    urlTemplate: '/speechtotext/v3.2/transcriptions/{jobId}'
    templateParameters: [
      {
        name: 'jobId'
        type: 'string'
        required: true
      }
    ]
  }
}

// ---------- Submit policy (POST /transcriptions) ----------
// ---------- Submit policy (POST /transcriptions) ----------
// Loaded from external XML so the policy is real, validatable XML.
var submitPolicyTemplate = loadTextContent('policies/submit-batch.policy.xml')

var submitPolicyXml = replace(replace(replace(replace(submitPolicyTemplate, '__PRIMARY_HOST__', speechPrimaryHost), '__SECONDARY_HOST__', speechSecondaryHost), '__PRIMARY_BACKEND__', backendPrimaryName), '__SECONDARY_BACKEND__', backendSecondaryName)

// ---------- Stateful policy (GET / DELETE on a specific jobId) ----------
var statefulPolicyXml = loadTextContent('policies/stateful.policy.xml')

resource submitBatchPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: submitBatchOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: submitPolicyXml
  }
  dependsOn: [
    backendPool
  ]
}

resource getBatchPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: getBatchOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statefulPolicyXml
  }
  dependsOn: [
    backendPool
  ]
}

resource getBatchFilesPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: getBatchFilesOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statefulPolicyXml
  }
  dependsOn: [
    backendPool
  ]
}

resource deleteBatchPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: deleteBatchOp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statefulPolicyXml
  }
  dependsOn: [
    backendPool
  ]
}

// ---------- App Insights logger + API diagnostic ----------
resource appInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger'
    credentials: {
      connectionString: appInsightsConnectionString
    }
    resourceId: appInsightsId
  }
}

resource speechApiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: speechApi
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    loggerId: appInsightsLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
  }
}

// ---- Outputs ----
output id string = apim.id
output name string = apim.name
output principalId string = apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
output sttApiPath string = speechApi.properties.path
