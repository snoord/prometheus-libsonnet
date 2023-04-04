// Library based on https://github.com/grafana/jsonnet-libs/tree/master/prometheus
local prometheusConfig = import 'github.com/crdsonnet/prometheus-libsonnet/prometheusConfig/main.libsonnet';
local k = import 'github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet';
local d = import 'github.com/jsonnet-libs/docsonnet/doc-util/main.libsonnet';

{
  new(
    namespace,
    name='prometheus',
    image='prom/prometheus:v2.43.0',
    watchImage='weaveworks/watch:master-0c44bf6',
    port=9090,
    pvcStorage='300Gi',
  ): {
    local this = self,

    name:: name,
    port:: port,
    path:: '/prometheus/',
    config_path:: '/etc/prometheus',
    config_file:: 'prometheus.yml',
    config: prometheusConfig.global.withScrapeInterval('15s'),

    local configMap = k.core.v1.configMap,
    config_map:
      configMap.new('%s-config' % name)
      + configMap.withData({
        [this.config_file]: k.util.manifestYaml(this.config),
      }),

    local container = k.core.v1.container,
    local volumeMount = k.core.v1.volumeMount,
    container::
      container.new('prometheus', image)
      + container.withPorts([
        k.core.v1.containerPort.new('http-metrics', port),
      ])
      + container.withArgs([
        '--config.file=%s' % std.join('/', [self.config_path, self.config_file]),
        '--web.listen-address=%s' % port,
        '--web.enable-admin-api',
        '--web.enable-lifecycle',
        '--web.route-prefix=%s' % this.path,
        '--storage.tsdb.path=/prometheus/data',
        '--storage.tsdb.wal-compression',
      ])
      + container.withVolumeMountsMixin(
        volumeMount.new(self.pvc.metadata.name, '/prometheus')
      )
      + k.util.resourcesRequests('250m', '1536Mi')
      + k.util.resourcesLimits('500m', '2Gi'),

    watch_container::
      container.new('watch', watchImage)
      + container.withArgs([
        '-v',
        '-t',
        '-p=' + self.config_path,
        'curl',
        '-X',
        'POST',
        '--fail',
        '-o',
        '-',
        '-sS',
        'http://localhost:%s%s-/reload' % [
          port,
          self.path,
        ],
      ]),

    local policyRule = k.rbac.v1.policyRule,
    rbac:
      (k { _config+: { namespace: namespace } }).util.rbac(
        name,
        [
          policyRule.withApiGroups([''])
          + policyRule.withResources([
            'nodes',
            'nodes/proxy',
            'services',
            'endpoints',
            'pods',
          ])
          + policyRule.withVerbs([
            'get',
            'list',
            'watch',
          ]),
          policyRule.withNonResourceUrls('/metrics')
          + policyRule.withVerbs(['get']),
        ]
      ),

    local pvc = k.core.v1.persistentVolumeClaim,
    pvc::
      pvc.new('%s-data' % (name))
      + pvc.spec.withAccessModes('ReadWriteOnce')
      + pvc.spec.resources.withRequests({ storage: pvcStorage }),

    local statefulset = k.apps.v1.statefulSet,
    statefulset:
      statefulset.new(
        name,
        1,  // use withHighAvailability(replicas) to increase
        [
          self.container,
          self.watch_container,
        ],
        self.pvc
      )
      + k.util.configVolumeMount(
        self.config_map.metadata.name,
        self.config_path,
      )
      + statefulset.spec.withPodManagementPolicy('Parallel')
      + statefulset.spec.withServiceName('prometheus')
      + statefulset.spec.template.metadata.withAnnotations({
        'prometheus.io.path': '%smetrics' % this.path,
      })
      + statefulset.spec.template.spec.withServiceAccount(
        self.rbac.service_account.metadata.name
      )
      + statefulset.spec.template.spec.securityContext.withFsGroup(2000)
      + statefulset.spec.template.spec.securityContext.withRunAsUser(1000)
      + statefulset.spec.template.spec.securityContext.withRunAsNonRoot(true)
      + k.util.podPriority('critical'),

    local service = k.core.v1.service,
    local servicePort = k.core.v1.servicePort,
    service:
      k.util.serviceFor(self.statefulset)
      + service.spec.withPortsMixin([
        servicePort.newNamed(
          name='http',
          port=80,
          targetPort=port,
        ),
      ]),
  },

  withEnabledFeatures(features): {
    container+:
      k.core.v1.container.withArgsMixin(
        '--enable-feature=%s' % std.join(',', features),
      ),
  },

  '#withExternalUrl'::
    d.func.new(
      |||
        `withExternalUrl` configures the external URL through which this 

        Example:

        ```jsonnet
        alertmanagerKube.new()
        + alertmanagerKube.withExternalUrl(
          'http://alertmanager.%s.svc.%s' % [
            namespace,
            dnsSuffix,
          ]
        )
        ```
      |||,
      args=[
        d.arg('config', d.T.object),
      ]
    ),
  withExternalUrl(hostname, path='/alertmanager/'): {
    path:: path,

    local container = k.core.v1.container,
    container::
      container.withArgsMixin([
        '--web.external-url=%s%s' % [
          self.hostname,
          self.path,
        ],
      ]),
  },

  withHighAvailability(replicas=2): (import './ha.libsonnet')(replicas=2),

  withMixins(mixins): (import './mixins.libsonnet')(mixins),

  withCoreMixin(): self.withMixins(import './coreMixin.libsonnet'),
}