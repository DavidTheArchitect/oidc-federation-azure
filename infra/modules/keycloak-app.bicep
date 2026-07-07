// Container App running Keycloak with a Caddy sidecar.
// Ingress (TLS, valid public cert) -> caddy :8080 -> keycloak 127.0.0.1:8081.
param location string
param appName string
param environmentId string
// Default domain of the managed environment; the app FQDN is
// '<appName>.<defaultDomain>' and is used as Keycloak's public hostname.
param environmentDefaultDomain string
param keycloakImage string = 'quay.io/keycloak/keycloak:26.3'
param caddyImage string = 'caddy:2'
param postgresFqdn string
param postgresLogin string
@secure()
param postgresPassword string
@secure()
param keycloakAdminPassword string
// Deployed as 'false' so bootstrap-keycloak.ps1 can reach the admin REST API;
// deploy.ps1 flips it to 'true' afterwards (new revision) to hide /admin, the
// master realm, and /metrics from the public internet.
param adminLockdown bool = false

var fqdn = '${appName}.${environmentDefaultDomain}'

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
      secrets: [
        {
          name: 'keycloak-admin-password'
          value: keycloakAdminPassword
        }
        {
          name: 'postgres-password'
          value: postgresPassword
        }
        {
          // Not sensitive - Container Apps secrets are used here only as the
          // mechanism to mount a file into the sidecar.
          name: 'caddyfile'
          #disable-next-line use-secure-value-for-secure-inputs
          value: loadTextContent('../../caddy/Caddyfile.aca')
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'caddy'
          image: caddyImage
          args: [
            'caddy'
            'run'
            '--config'
            '/etc/caddy/caddyfile'
            '--adapter'
            'caddyfile'
          ]
          env: [
            {
              name: 'CADDY_ADMIN_LOCKDOWN'
              value: string(adminLockdown)
            }
          ]
          volumeMounts: [
            {
              volumeName: 'caddy-config'
              mountPath: '/etc/caddy'
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
        }
        {
          name: 'keycloak'
          image: keycloakImage
          args: [
            'start'
          ]
          env: [
            {
              name: 'KC_DB'
              value: 'postgres'
            }
            {
              name: 'KC_DB_URL'
              value: 'jdbc:postgresql://${postgresFqdn}:5432/keycloak?sslmode=require'
            }
            {
              name: 'KC_DB_USERNAME'
              value: postgresLogin
            }
            {
              name: 'KC_DB_PASSWORD'
              secretRef: 'postgres-password'
            }
            {
              name: 'KC_BOOTSTRAP_ADMIN_USERNAME'
              value: 'admin'
            }
            {
              name: 'KC_BOOTSTRAP_ADMIN_PASSWORD'
              secretRef: 'keycloak-admin-password'
            }
            {
              name: 'KC_HOSTNAME'
              value: 'https://${fqdn}'
            }
            {
              name: 'KC_HTTP_ENABLED'
              value: 'true'
            }
            {
              name: 'KC_HTTP_PORT'
              value: '8081'
            }
            {
              name: 'KC_PROXY_HEADERS'
              value: 'xforwarded'
            }
            {
              name: 'KC_HEALTH_ENABLED'
              value: 'true'
            }
          ]
          resources: {
            cpu: json('1.0')
            memory: '2.0Gi'
          }
          probes: [
            {
              type: 'Startup'
              httpGet: {
                path: '/health/started'
                port: 9000
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              failureThreshold: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: 9000
              }
              periodSeconds: 10
              failureThreshold: 3
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/live'
                port: 9000
              }
              periodSeconds: 30
              failureThreshold: 3
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'caddy-config'
          storageType: 'Secret'
          secrets: [
            {
              secretRef: 'caddyfile'
              path: 'caddyfile'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
