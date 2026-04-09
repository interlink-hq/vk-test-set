// A Dagger module to run vk-test-set end-to-end tests against interLink components
//
// Visit the interLink documentation for more info: https://interlink-hq.github.io/interLink/docs/intro/

package main

import (
	"context"
	"dagger/vk-test-set/internal/dagger"
	"fmt"
	"time"
)

// vkConfigMap is the ConfigMap that configures virtual-kubelet to connect to the interLink service
const vkConfigMap = `apiVersion: v1
kind: ConfigMap
metadata:
  name: virtual-kubelet-config
  namespace: interlink
data:
  InterLinkConfig.yaml: |
    InterlinkURL: "http://interlink"
    InterlinkPort: "3000"
    VerboseLogging: true
    ErrorsOnlyLogging: false
    ServiceAccount: "virtual-kubelet"
    Namespace: interlink
    VKTokenFile: ""
    Resources:
      CPU: "100"
      Memory: "128Gi"
      Pods: "100"
    HTTP:
      Insecure: true
    KubeletHTTP:
      Insecure: true
`

// VkTestSet is the Dagger module for vk-test-set e2e tests
type VkTestSet struct {
	Name              string
	VirtualKubeletRef string
	InterlinkRef      string
	PluginRef         string
}

// New initializes the Dagger module
func New(
	name string,
	// +optional
	// +default="ghcr.io/interlink-hq/interlink/virtual-kubelet-inttw:0.6.0"
	virtualKubeletRef string,
	// +optional
	// +default="ghcr.io/interlink-hq/interlink/interlink:0.6.0"
	interlinkRef string,
	// +optional
	// +default="ghcr.io/interlink-hq/interlink-sidecar-slurm/interlink-sidecar-slurm:0.5.0"
	pluginRef string,
) *VkTestSet {
	return &VkTestSet{
		Name:              name,
		VirtualKubeletRef: virtualKubeletRef,
		InterlinkRef:      interlinkRef,
		PluginRef:         pluginRef,
	}
}

// NewInterlink sets up a k3s cluster with the interLink API, slurm mock plugin, and virtual-kubelet
func (m *VkTestSet) NewInterlink(
	ctx context.Context,
	// +optional
	// +defaultPath="./manifests"
	manifests *dagger.Directory,
	// +optional
	// +defaultPath="./manifests/interlink-config.yaml"
	interlinkConfig *dagger.File,
	// +optional
	// +defaultPath="./manifests/plugin-config.yaml"
	pluginConfig *dagger.File,
) (*VkTestSet, error) {
	// Start the slurm plugin service (SHARED_FS=true enables mock mode without real SLURM)
	pluginEndpoint, err := dag.Container().From(m.PluginRef).
		WithFile("/etc/interlink/InterLinkConfig.yaml", pluginConfig).
		WithEnvVariable("BUST", time.Now().String()).
		WithEnvVariable("SLURMCONFIGPATH", "/etc/interlink/InterLinkConfig.yaml").
		WithEnvVariable("SHARED_FS", "true").
		WithExposedPort(4000).
		AsService(dagger.ContainerAsServiceOpts{
			UseEntrypoint:            true,
			InsecureRootCapabilities: true,
		}).Start(ctx)
	if err != nil {
		return nil, err
	}

	// Start the interLink API service, bound to the plugin
	interlinkEndpoint, err := dag.Container().From(m.InterlinkRef).
		WithFile("/etc/interlink/InterLinkConfig.yaml", interlinkConfig).
		WithEnvVariable("BUST", time.Now().String()).
		WithServiceBinding("plugin", pluginEndpoint).
		WithEnvVariable("INTERLINKCONFIGPATH", "/etc/interlink/InterLinkConfig.yaml").
		WithExposedPort(3000).
		AsService(dagger.ContainerAsServiceOpts{
			UseEntrypoint:            true,
			InsecureRootCapabilities: true,
		}).Start(ctx)
	if err != nil {
		return nil, err
	}

	// Set up k3s cluster with the interLink service accessible as "interlink"
	K3s := dag.K3S(m.Name).With(func(k *dagger.K3S) *dagger.K3S {
		return k.WithContainer(
			k.Container().
				WithEnvVariable("BUST", time.Now().String()).
				WithServiceBinding("interlink", interlinkEndpoint),
		)
	})

	_, err = K3s.Server().Start(ctx)
	if err != nil {
		return nil, err
	}

	time.Sleep(60 * time.Second) // wait for k3s to be ready

	kubeConfig := K3s.Config(dagger.K3SConfigOpts{Local: false})

	// Build VK deployment YAML with the configured image reference
	vkDeploymentYAML := fmt.Sprintf(`apiVersion: apps/v1
kind: Deployment
metadata:
  name: virtual-kubelet
  namespace: interlink
  labels:
    nodeName: virtual-kubelet
spec:
  replicas: 1
  selector:
    matchLabels:
      nodeName: virtual-kubelet
  template:
    metadata:
      labels:
        nodeName: virtual-kubelet
    spec:
      hostNetwork: true
      automountServiceAccountToken: true
      serviceAccountName: virtual-kubelet
      containers:
      - name: inttw-vk
        image: "%s"
        imagePullPolicy: Always
        env:
        - name: NODENAME
          value: virtual-kubelet
        - name: KUBELET_PORT
          value: "10251"
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: CONFIGPATH
          value: "/etc/interlink/InterLinkConfig.yaml"
        volumeMounts:
        - name: config
          mountPath: /etc/interlink/InterLinkConfig.yaml
          subPath: InterLinkConfig.yaml
      volumes:
      - name: config
        configMap:
          name: virtual-kubelet-config
`, m.VirtualKubeletRef)

	// Deploy virtual-kubelet and its supporting resources into k3s
	_, err = dag.Container().From("bitnamilegacy/kubectl:1.33-debian-12").
		WithUser("root").
		WithMountedFile("/.kube/config", kubeConfig).
		WithEnvVariable("KUBECONFIG", "/.kube/config").
		WithEnvVariable("BUST", time.Now().String()).
		WithDirectory("/manifests", manifests).
		WithNewFile("/manifests/virtual-kubelet-config.yaml", vkConfigMap).
		WithNewFile("/manifests/virtual-kubelet-deployment.yaml", vkDeploymentYAML).
		WithExec([]string{"bash", "-c", `
			kubectl create namespace interlink --dry-run=client -o yaml | kubectl apply -f - &&
			kubectl apply -f /manifests/service-account.yaml &&
			kubectl apply -f /manifests/virtual-kubelet-config.yaml &&
			kubectl apply -f /manifests/virtual-kubelet-deployment.yaml &&
			kubectl wait --for=condition=Available deployment/virtual-kubelet -n interlink --timeout=300s &&
			kubectl wait --for=condition=Ready node/virtual-kubelet --timeout=300s
		`}).
		Sync(ctx)
	if err != nil {
		return nil, err
	}

	return m, nil
}

// Test installs the vk-test-set and runs the pytest suite against the running cluster
func (m *VkTestSet) Test(
	ctx context.Context,
	// +optional
	// +defaultPath=".."
	testSet *dagger.Directory,
	// +optional
	// +defaultPath="./manifests"
	manifests *dagger.Directory,
) (*dagger.Container, error) {
	c := dag.Container().From("bitnamilegacy/kubectl:1.33-debian-12").
		WithUser("root").
		WithExec([]string{"mkdir", "-p", "/opt/user"}).
		WithExec([]string{"chown", "-R", "1001:0", "/opt/user"}).
		WithExec([]string{"apt", "update"}).
		WithExec([]string{"apt", "install", "-y", "curl", "python3", "python3-pip", "python3-venv", "git"}).
		WithMountedFile("/.kube/config", dag.K3S(m.Name).Config(dagger.K3SConfigOpts{Local: false})).
		WithExec([]string{"chown", "1001:0", "/.kube/config"}).
		WithUser("1001").
		WithDirectory("/manifests", manifests).
		WithDirectory("/opt/user/vk-test-set", testSet, dagger.ContainerWithDirectoryOpts{Owner: "1001:0"}).
		WithEntrypoint([]string{"kubectl"}).
		WithExec([]string{"bash", "-c", "cp /manifests/vktest_config.yaml /opt/user/vk-test-set/vktest_config.yaml"}).
		WithWorkdir("/opt/user/vk-test-set").
		WithExec([]string{"bash", "-c", "kubectl get csr -o name | xargs -r kubectl certificate approve"}).
		WithExec([]string{"bash", "-c", "python3 -m venv .venv && source .venv/bin/activate && pip3 install -e ./"})

	result := c.
		WithExec([]string{"bash", "-c", "kubectl get csr -o name | xargs -r kubectl certificate approve"}).
		WithExec([]string{"bash", "-c", "source .venv/bin/activate && export KUBECONFIG=/.kube/config && pytest -v -k 'not rclone and not limits and not stress and not multi-init and not fail'"})

	return result, nil
}
