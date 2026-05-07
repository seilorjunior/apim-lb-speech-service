// =====================================================================
// modules/keyvault.bicep
// Key Vault used as the canonical store for the AMR (Azure Managed
// Redis) connection string consumed by the APIM external cache.
//
// Why centralize the AMR connection string here?
//   * Removes the need to suppress the `use-secure-value-for-secure-inputs`
//     Bicep linter warning in apim.bicep — the secret flows through a
//     `@secure()` module parameter sourced from this vault.
//   * Lets a human (or future rotation tooling) inspect / rotate the
//     secret from the Key Vault side, independent of the APIM resource.
//
// CAVEAT — runtime rotation is NOT automatic.
//   The ARM property `Microsoft.ApiManagement/service/caches.connectionString`
//   is a literal string, NOT a runtime KV reference (the
//   `@Microsoft.KeyVault(SecretUri=...)` syntax is App Service-specific).
//   Rotating the secret in this vault therefore requires a redeploy
//   (or a manual REST PATCH) of the cache resource for APIM to pick up
//   the new value.
// =====================================================================

@description('Key Vault name (3-24 chars, alphanumeric + dashes).')
@minLength(3)
@maxLength(24)
param name string

@description('Region for the vault.')
param location string

@description('Resource tags.')
param tags object

@description('When true, enables purge protection on the vault. Recommended for non-dev environments. CAVEAT: irreversible — once true the property cannot be disabled. The vault (and all secret history) will then be retained for the full soft-delete retention period regardless of whether the vault itself is deleted. Leave false in dev / preview environments where teardown via `azd down` is expected.')
param purgeProtectionEnabled bool = false

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true       // modern auth model (no access policies)
    publicNetworkAccess: 'Enabled'      // dev-only; lock down with privateLink for prod
    enableSoftDelete: true
    softDeleteRetentionInDays: 7        // shortest allowed; matches dev posture
    // Only emit the property when explicitly opting in. Setting it to
    // `false` after it was previously `true` is rejected by ARM, so we
    // keep the property absent in dev rather than risk a future redeploy
    // toggling back to false.
    enablePurgeProtection: purgeProtectionEnabled ? true : null
    enabledForTemplateDeployment: true  // allows ARM nested deployments to resolve
                                        // KV references (defensive — not strictly
                                        // required by this template since we pass
                                        // the secret value directly via @secure
                                        // module params, not via @Microsoft.KeyVault
                                        // references).
  }
}

output id string = kv.id
output name string = kv.name
output uri string = kv.properties.vaultUri
