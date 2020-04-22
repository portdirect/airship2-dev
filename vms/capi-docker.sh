#!/bin/bash

VM_NAME=capi-docker

VM_TYPE=capi-docker

sudo virsh destroy ${VM_NAME}
sudo virsh undefine ${VM_NAME}
sudo rm -rv /var/lib/libvirt/images/${VM_NAME}.qcow2 /var/lib/libvirt/boot/${VM_NAME}_config.iso

sudo qemu-img create -f qcow2 -o \
    backing_file=/var/lib/libvirt/images/base/bionic-server-cloudimg-amd64.qcow2 \
    /var/lib/libvirt/images/${VM_NAME}.qcow2
sudo qemu-img resize /var/lib/libvirt/images/${VM_NAME}.qcow2 +250G

sudo genisoimage -o /var/lib/libvirt/boot/${VM_NAME}_config.iso -V cidata -r -J ./${VM_TYPE}/meta-data ./${VM_TYPE}/network-config ./${VM_TYPE}/user-data
#sudo semanage fcontext -a -t svirt_image_t "/var/home/harbor/Development(/.*)?"
#sudo restorecon -R /var/home/harbor/Development
sudo virt-install --connect qemu:///system \
         --os-variant ubuntu18.04 \
         --name ${VM_NAME} \
         --memory 131071 \
         --memorybacking hugepages=on \
         --network bridge=bridge0,mac=DE:AD:BE:EF:72:3D \
         --network network=default \
         --cpu host-passthrough \
         --vcpus 16,cpuset=4-7,12-32 \
         --import \
         --disk path=/var/lib/libvirt/images/${VM_NAME}.qcow2 \
         --disk path=/var/lib/libvirt/boot/${VM_NAME}_config.iso,device=cdrom \
         --nographics \
         --noautoconsole \
         --filesystem=/var/home/harbor/Development,/host-development

sudo virsh domifaddr ${VM_NAME}

ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$(sudo virsh domifaddr ${VM_NAME} --interface vnet1 | awk '/vnet1/ { print $NF ; exit}' | awk -F '/' '{ print $1 }')





CA_K8S=$(mktemp -d)
openssl genrsa -out ${CA_K8S}/ca.key 2048
openssl req -x509 -new -nodes -key ${CA_K8S}/ca.key -subj "/CN=Kubernetes API CA" -days 3650 -reqexts v3_req -extensions v3_ca -out ${CA_K8S}/ca.crt
#https://cluster-api.sigs.k8s.io/tasks/certs/using-custom-certificates.html
WORKLOAD_CLUSTER_NAME=workload-cluster
cat <<EOF | kubectl-m apply -f -
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: ${WORKLOAD_CLUSTER_NAME}-ca
  namespace: default
  labels:
    cluster.airshipit.io/cluster-name: ${WORKLOAD_CLUSTER_NAME}
data:
  tls.crt: $(cat ${CA_K8S}/ca.crt | base64 -w0)
  tls.key: $(cat ${CA_K8S}/ca.key | base64 -w0)
EOF

CA_ETCD=$(mktemp -d)
openssl genrsa -out ${CA_ETCD}/ca.key 2048
openssl req -x509 -new -nodes -key ${CA_ETCD}/ca.key -subj "/CN=ETCD CA" -days 3650 -reqexts v3_req -extensions v3_ca -out ${CA_ETCD}/ca.crt
#https://cluster-api.sigs.k8s.io/tasks/certs/using-custom-certificates.html
WORKLOAD_CLUSTER_NAME=workload-cluster
cat <<EOF | kubectl-m apply -f -
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: ${WORKLOAD_CLUSTER_NAME}-etcd
  namespace: default
  labels:
    cluster.airshipit.io/cluster-name: ${WORKLOAD_CLUSTER_NAME}
data:
  tls.crt: $(cat ${CA_ETCD}/ca.crt | base64 -w0)
  tls.key: $(cat ${CA_ETCD}/ca.key | base64 -w0)
EOF

CA_PROXY=$(mktemp -d)
openssl genrsa -out ${CA_PROXY}/ca.key 2048
openssl req -x509 -new -nodes -key ${CA_PROXY}/ca.key -subj "/CN=Front-End Proxy" -days 3650 -reqexts v3_req -extensions v3_ca -out ${CA_PROXY}/ca.crt
#https://cluster-api.sigs.k8s.io/tasks/certs/using-custom-certificates.html
WORKLOAD_CLUSTER_NAME=workload-cluster
cat <<EOF | kubectl-m apply -f -
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: ${WORKLOAD_CLUSTER_NAME}-proxy
  namespace: default
  labels:
    cluster.airshipit.io/cluster-name: ${WORKLOAD_CLUSTER_NAME}
data:
  tls.crt: $(cat ${CA_PROXY}/ca.crt | base64 -w0)
  tls.key: $(cat ${CA_PROXY}/ca.key | base64 -w0)
EOF

mkdir -p  ~/capi-dev/clusters
tee ~/capi-dev/clusters/workload-cluster.yaml <<'EOF'
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha3
kind: DockerCluster
metadata:
  name: workload-cluster
  namespace: default
---
apiVersion: cluster.x-k8s.io/v1alpha3
kind: Cluster
metadata:
  name: workload-cluster
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 172.19.0.0/18
    serviceDomain: cluster.local
    services:
      cidrBlocks:
      - 172.19.64.0/18
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1alpha3
    kind: DockerCluster
    name: workload-cluster
    namespace: default
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha3
kind: DockerMachine
metadata:
  name: controlplane-0
  namespace: default
---
apiVersion: cluster.x-k8s.io/v1alpha3
kind: Machine
metadata:
  labels:
    cluster.x-k8s.io/cluster-name: workload-cluster
    cluster.x-k8s.io/control-plane: "true"
  name: controlplane-0
  namespace: default
spec:
  bootstrap:
    configRef:
      apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
      kind: KubeadmConfig
      name: controlplane-0-config
      namespace: default
  clusterName: workload-cluster
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1alpha3
    kind: DockerMachine
    name: controlplane-0
    namespace: default
  version: 1.17.0
---
apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
kind: KubeadmConfig
metadata:
  name: controlplane-0-config
  namespace: default
spec:
  files:
  - path: "/etc/kubernetes/etcd-encryption.yaml"
    owner: root:root
    permissions: '0640'
    content: |
      ---
      apiVersion: apiserver.config.k8s.io/v1
      kind: EncryptionConfiguration
      resources:
      - resources:
        - secrets
        providers:
        - aescbc:
            keys:
            - name: key1
              secret: pSt42jZGTQ6XujtzUGzw2JxScm9Mk2ifIqRACeh6oa0=
        - identity: {}
  clusterConfiguration:
    controllerManager:
      extraArgs:
        enable-hostpath-provisioner: 'true'
    apiServer:
      extraArgs:
        service-node-port-range: 80-32767
        encryption-provider-config: "/etc/kubernetes/etcd-encryption.yaml"
        oidc-issuer-url: https://vm-capi-docker.lan:5556/dex
        oidc-client-id: my-cluster
        oidc-ca-file: "/etc/kubernetes/pki/ca.crt"
        oidc-username-claim: name
        oidc-username-prefix: 'oidc:'
        oidc-groups-claim: groups
        oidc-groups-prefix: 'oidc:'
      extraVolumes:
      - name: etcd-encryption
        hostPath: "/etc/kubernetes/etcd-encryption.yaml"
        mountPath: "/etc/kubernetes/etcd-encryption.yaml"
      certSANs:
      - "vm-capi-docker.lan"
  initConfiguration:
    nodeRegistration:
      kubeletExtraArgs:
        eviction-hard: nodefs.available<0%,nodefs.inodesFree<0%,imagefs.available<0%
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha3
kind: DockerMachine
metadata:
  name: worker-0
  namespace: default
---
apiVersion: cluster.x-k8s.io/v1alpha3
kind: Machine
metadata:
  labels:
    cluster.x-k8s.io/cluster-name: workload-cluster
  name: worker-0
  namespace: default
spec:
  bootstrap:
    configRef:
      apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
      kind: KubeadmConfig
      name: worker-0-config
      namespace: default
  clusterName: workload-cluster
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1alpha3
    kind: DockerMachine
    name: worker-0
    namespace: default
  version: 1.17.0
---
apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
kind: KubeadmConfig
metadata:
  name: worker-0-config
  namespace: default
spec:
  joinConfiguration:
    nodeRegistration:
      kubeletExtraArgs:
        eviction-hard: nodefs.available<0%,nodefs.inodesFree<0%,imagefs.available<0%
EOF

kubectl-m apply -f ~/capi-dev/clusters/workload-cluster.yaml
#kubectl --kubeconfig $HOME/.kube/workload-cluster/config delete -f ~/capi-dev/clusters/workload-cluster.yaml

mkdir -p $HOME/.kube/workload-cluster
kubectl-m --namespace=default get secret workload-cluster-kubeconfig -o 'go-template={{ .data.value | base64decode }}' > $HOME/.kube/workload-cluster/config

kubectl-w get nodes -o wide
curl -sSL https://docs.projectcalico.org/v3.12/manifests/calico.yaml | sed 's|192.168.0.0/16|172.19.0.0/18|g' | kubectl-w apply -f -



cat ~/capi-dev/images.txt | xargs -L1 -r kind load docker-image --name workload-cluster
clusterctl-w init --core cluster-api:v0.3.0 --bootstrap kubeadm:v0.3.0 --control-plane kubeadm:v0.3.0 --infrastructure docker:v0.3.0
clusterctl-m move --namespace default --to-kubeconfig $HOME/.kube/workload-cluster/config

kubectl-m get secrets -l cluster.airshipit.io/cluster-name=${WORKLOAD_CLUSTER_NAME} -o=json | jq 'del(.items[].metadata.annotations."kubectl.kubernetes.io/last-applied-configuration") | del(.items[].metadata.creationTimestamp) | del(.items[].metadata.resourceVersion) | del(.items[].metadata.selfLink) | del(.items[].metadata.uid)' | kubectl --kubeconfig $HOME/.kube/workload-cluster/config apply -f -

#kind delete cluster --name=management-cluster

cat <<EOF | kubectl-w apply -f -
apiVersion: cert-manager.io/v1alpha2
kind: Issuer
metadata:
  name: workload-cluster-ca-issuer
  namespace: default
spec:
  ca:
    secretName: workload-cluster-ca
EOF











cat <<EOF | kubectl-w apply -f -
apiVersion: cert-manager.io/v1alpha2
kind: Certificate
metadata:
  name: dex
  namespace: default
spec:
  secretName: dex-tls
  issuerRef:
    name: workload-cluster-ca-issuer
    # We can reference ClusterIssuers by changing the kind here.
    # The default value is Issuer (i.e. a locally namespaced Issuer)
    kind: Issuer
  commonName: vm-capi-docker.lan
  organization:
  - Kubernetes API CA
  dnsNames:
  - vm-capi-docker.lan
EOF


cat <<EOF | kubectl-w apply -f -
---
# Source: dex/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: asoidc-dex
  labels:
    app: asoidc-dex
    env: dev
    chart: dex-1.2.0
    release: "asoidc"
    heritage: "Helm"
EOF
cat <<EOF | kubectl-w apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: asoidc-dex
  labels:
    app: asoidc-dex
    env: dev
    chart: "dex-1.2.0"
    release: "asoidc"
    heritage: "Helm"
data:
  ldap-bindpw: "b3ZlcnJpZGUtbWU="
EOF

cat <<'EOF' | kubectl-w apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: asoidc-dex
  labels:
    app: asoidc-dex
    env: dev
    chart: "dex-1.2.0"
    release: "asoidc"
    heritage: "Helm"
data:
  config.yaml: |-
    issuer: https://vm-capi-docker.lan:5556/dex

    storage:
      type: kubernetes
      config:
        inCluster: true

    web:
      https: 0.0.0.0:5556
      tlsCert: /etc/dex/tls/tls.crt
      tlsKey: /etc/dex/tls/tls.key

    frontend:
      theme: "coreos"
      issuer: "Example Co"
      issuerUrl: "https://example.com"
      logoUrl: https://example.com/images/logo-250x25.png

    expiry:
      signingKeys: "6h"
      idTokens: "24h"

    logger:
      level: debug
      format: json

    oauth2:
      responseTypes: ["code", "token", "id_token"]
      skipApprovalScreen: true

    #TODO SETUP LDAP CONNECTOR
    #connectors:

    # The 'name' must match the k8s API server's 'oidc-client-id'
    staticClients:
    - id: my-cluster
      name: "my-cluster"
      secret: "pUBnBOY80SnXgjibTYM9ZWNzY2xreNGQok"
      redirectURIs:
      - https://vm-capi-docker.lan:5555/ui/callback/my-cluster

    enablePasswordDB: True
    staticPasswords:
    - email: "admin@example.com"
      # bcrypt hash of the string "password"
      hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
      username: "admin"
      userID: "08a8684b-db88-4b73-90a9-3cd1661f5466"
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  name: asoidc-dex
rules:
- apiGroups:
  - apiextensions.k8s.io
  resources:
  - customresourcedefinitions
  verbs:
  - "*"
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: asoidc-dex
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: asoidc-dex
subjects:
- kind: ServiceAccount
  name: asoidc-dex
  namespace: default
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: Role
metadata:
  name: asoidc-dex
  namespace: default
rules:
- apiGroups:
  - dex.coreos.com
  resources:
  - authcodes
  - authrequests
  - connectors
  - oauth2clients
  - offlinesessionses
  - passwords
  - refreshtokens
  - signingkeies
  verbs:
  - "*"
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: RoleBinding
metadata:
  name: asoidc-dex
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: asoidc-dex
subjects:
- kind: ServiceAccount
  name: asoidc-dex
  namespace: default
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: v1
kind: Service
metadata:
  name: asoidc-dex
  labels:
    app: dex
    env: dev
    chart: dex-1.2.0
    release: asoidc
    heritage: Helm
spec:
  type: NodePort
  ports:
  - port: 5556
    targetPort: http
    protocol: TCP
    name: http
    nodePort: 5556
  selector:
    app: dex
    release: asoidc
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: asoidc-dex
  labels:
    app: dex
    env: dev
    chart: dex-1.2.0
    release: asoidc
    heritage: Helm
  annotations:
    scheduler.alpha.kubernetes.io/critical-pod: ''
spec:
  replicas: 1
  minReadySeconds: 30
  strategy:
    rollingUpdate:
      maxUnavailable: 0
  selector:
    matchLabels:
      app: dex
      env: dev
      release: asoidc
  template:
    metadata:
      labels:
        app: dex
        env: dev
        release: asoidc
      annotations:
        checksum/config: 75e5b0ab554add775d04b76986ecc566a427de421356173114efa0c05db92520
    spec:
      volumes:
      - name: config
        configMap:
          name: asoidc-dex
          items:
          - key: config.yaml
            path: config.yaml
      - name: tls
        secret:
          secretName: dex-tls
      serviceAccountName: asoidc-dex
      containers:
      - name: dex
        image: "quay.io/dexidp/dex:v2.20.0"
        imagePullPolicy: IfNotPresent
        command: ["/usr/local/bin/dex", "serve", "/etc/dex/config.yaml"]
 #       env:
 #       - name: LDAP_BINDPW
 #         valueFrom:
 #           secretKeyRef:
 #             name: asoidc-dex
 #             key: ldap-bindpw
        ports:
        - name: http
          containerPort: 5556
          protocol: TCP
        livenessProbe:
          httpGet:
            scheme: HTTPS
            path: /dex/healthz
            port: 5556
        readinessProbe:
          httpGet:
            scheme: HTTPS
            path: /dex/healthz
            port: 5556
          initialDelaySeconds: 5
          timeoutSeconds: 1
        volumeMounts:
        - name: config
          mountPath: /etc/dex
        - name: tls
          mountPath: /etc/dex/tls
EOF















cat <<EOF | kubectl-w apply -f -
# Source: dex-k8s-authenticator/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mintel-dex-dex-k8s-authenticator
  labels:
    app: mintel-dex-dex-k8s-authenticator
    env: dev
    chart: "dex-k8s-authenticator-1.2.0"
    release: "mintel-dex"
    heritage: "Helm"
data:
  config.yaml: |-
    listen: https://0.0.0.0:5555
    web_path_prefix: /ui
    tls_cert: /tls/tls.crt
    tls_key: /tls/tls.key
    debug: true
    clusters:
    - client_id: my-cluster
      client_secret: pUBnBOY80SnXgjibTYM9ZWNzY2xreNGQok
      description: Example Cluster Long Description...
      issuer: https://vm-capi-docker.lan:5556/dex
      k8s_ca_uri: http://vm-capi-docker.lan:5554/ca.crt
      k8s_master_uri: https://vm-capi-docker.lan:6443/
      name: my-cluster
      redirect_uri: https://vm-capi-docker.lan:5555/ui/callback/my-cluster
      short_description: My Cluster
EOF


cat <<EOF | kubectl-w apply -f -
# Source: dex-k8s-authenticator/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: mintel-dex-dex-k8s-authenticator
  labels:
    app: dex-k8s-authenticator
    env: dev
    chart: dex-k8s-authenticator-1.2.0
    release: mintel-dex
    heritage: Helm
spec:
  type: NodePort
  ports:
  - port: 5555
    targetPort: http
    protocol: TCP
    name: http
    nodePort: 5555
  selector:
    app: dex-k8s-authenticator
    release: mintel-dex
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mintel-dex-dex-k8s-authenticator
  labels:
    app: dex-k8s-authenticator
    env: dev
    chart: dex-k8s-authenticator-1.2.0
    release: mintel-dex
    heritage: Helm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dex-k8s-authenticator
      env: dev
      release: mintel-dex
  template:
    metadata:
      labels:
        app: dex-k8s-authenticator
        env: dev
        release: mintel-dex
      annotations:
        checksum/config: a411eb94d21b560b92537e464c1bf596c815ac15a72a4423f46aaceab41da6d7
    spec:
      containers:
      - name: dex-k8s-authenticator
        image: "mintel/dex-k8s-authenticator:1.2.0"
        imagePullPolicy: Always
        command:
         - /entrypoint.sh
        args: [ "--config", "/app/config.yaml" ]
        ports:
        - name: http
          containerPort: 5555
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /ui/healthz
            port: http
            scheme: HTTPS
        readinessProbe:
          httpGet:
            path: /ui/healthz
            port: http
            scheme: HTTPS
        volumeMounts:
        - name: config
          subPath: config.yaml
          mountPath: /app/config.yaml
        - name: tls-ca
          mountPath: /certs/
        - name: tls-cert
          mountPath: /tls/
        resources:
          {}
      volumes:
      - name: config
        configMap:
          name: mintel-dex-dex-k8s-authenticator
      - name: tls-ca
        secret:
          secretName: dex-tls
          items:
          - key: ca.crt
            path: ca.crt
      - name: tls-cert
        secret:
          secretName: dex-tls
          items:
          - key: tls.crt
            path: tls.crt
          - key: tls.key
            path: tls.key
EOF


cat <<EOF | kubectl-w apply -f -
# Source: dex-k8s-authenticator/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ca-server
  labels:
    app: ca-server
spec:
  type: NodePort
  ports:
  - port: 5554
    targetPort: http
    protocol: TCP
    name: http
    nodePort: 5554
  selector:
    app: ca-server
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ca-server
  labels:
    app: ca-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ca-server
  template:
    metadata:
      labels:
        app: ca-server
    spec:
      containers:
      - name: ca-server
        image: "docker.io/nginx:1.17.10-alpine"
        imagePullPolicy: Always
        command:
         - nginx 
        args:
         - -g
         - 'daemon off;'
        ports:
        - name: http
          containerPort: 80
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /ca.crt
            port: http
        readinessProbe:
          httpGet:
            path: /ca.crt
            port: http
        volumeMounts:
        - name: tls-ca
          mountPath: /usr/share/nginx/html/
        resources:
          {}
      volumes:
      - name: tls-ca
        secret:
          secretName: dex-tls
          items:
          - key: ca.crt
            path: ca.crt
EOF

cat <<EOF | kubectl-w apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc:admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: "oidc:admin"
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: "oidc:admins"
EOF



workload_cluster_master_host_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' workload-cluster-controlplane-0)
hproxy_config=$(mktemp --suffix=.cfg)
tee ${hproxy_config} <<EOF
global
  log /dev/log local0
  log /dev/log local1 notice
  daemon
defaults
  log global
  mode tcp
  option dontlognull
  # TODO: tune these
  timeout connect 5000
  timeout client 50000
  timeout server 50000

frontend kube-apiserver
  bind *:6443
    default_backend kube-apiservers
backend kube-apiservers
  server workload-cluster-controlplane-0 ${workload_cluster_master_host_ip}:6443 check check-ssl verify none

frontend dex
  bind *:5556
    default_backend dex
backend dex
  server workload-cluster-controlplane-0 ${workload_cluster_master_host_ip}:5556 check check-ssl verify none

frontend dex-ui
  bind *:5555
    default_backend dex-ui
backend dex-ui
  server workload-cluster-controlplane-0 ${workload_cluster_master_host_ip}:5555 check check-ssl verify none

frontend dex-ca
  bind *:5554
    default_backend dex-ca
backend dex-ca
  server workload-cluster-controlplane-0 ${workload_cluster_master_host_ip}:5554 check verify none
EOF

docker run --net=host -d --name workload-proxy -v ${hproxy_config}:${hproxy_config}:ro --entrypoint /usr/local/sbin/haproxy kindest/haproxy:2.1.1-alpine -W -db -f ${hproxy_config} -sf 6


