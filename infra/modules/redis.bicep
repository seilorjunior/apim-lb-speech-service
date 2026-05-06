// =====================================================================
// modules/redis.bicep
// Azure Managed Redis (Microsoft.Cache/redisEnterprise) used as the
// APIM external cache for jobId -> backend pinning.
//
// Why AMR instead of the APIM built-in cache?
//   * Survives APIM scale-out / updates (built-in cache is per-unit and
//     gets cleared on platform updates).
//   * Lets you actually inspect / clear the keys from the Redis side.
//
// The smallest dev-tier SKU is Balanced_B0 (~$80/month at the time of
// writing). Override via the skuName parameter for production loads.
// =====================================================================

@description('Cluster name (must be valid: 1-60 chars, alphanumeric + dashes).')
@minLength(1)
@maxLength(60)
param name string

@description('Region for the Redis cluster.')
param location string

@description('Resource tags.')
param tags object

@description('AMR SKU. Balanced_B0 is the cheapest dev tier.')
param skuName string = 'Balanced_B0'

resource cluster 'Microsoft.Cache/redisEnterprise@2025-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    minimumTlsVersion: '1.2'
  }
}

// One database per cluster (the only supported topology today). Named
// "default" is the convention used by the portal-generated templates.
resource db 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' = {
  parent: cluster
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'           // TLS only
    port: 10000                            // AMR default
    clusteringPolicy: 'EnterpriseCluster' // single endpoint via proxy
    evictionPolicy: 'NoEviction'           // do not auto-evict pin entries
    accessKeysAuthentication: 'Enabled'   // APIM external cache requires
                                           // access-key auth (Entra is
                                           // not supported by APIM yet).
  }
}

// ---- Outputs ----
output id string = cluster.id
output name string = cluster.name
output databaseName string = db.name
output hostName string = cluster.properties.hostName
output port int = 10000
