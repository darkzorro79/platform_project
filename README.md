# platform_project
## Проектная работа по kubernetes

## 0. В курсовой работе разверну микросервисный проект https://datahubproject.io/
так же будет присутстовать мониторинг на основе Prometheus + grafana, за логи будет отвечать Loghous + fluentd, CI/CD будет предствлен ArgoCD 
В ArgoCD я не буду помещать основной прокет Datahub - по причине 2-х поочерёдных helm чартов которые в первом случае готовят почву для развёртования сервера, а вторым уже наливают данные и запускают frontend, 
поэтому решаю, что для простоты в качестве примера разверну Loghous + fluentd, благо что там один helm chart.

В качестве провайдера kubernetes я не буду выбирать никого, проект строго Bare metal.
"Железо" представлено в качестве набора виртуальных машин на ESXi (vCenter) VmWare vSphera, которые в 1 пункте попытаемся задеплоить из шаблона с помощью Ansible/Terraform.

Так как в основном проекте есть elasticsearch который для отказоустойчивости требует 3 ноды - то у нас в кластере Kubernetes будет 3 worker ноды, 3 мастер ноды и 2 ingess ноды.
Сетевая схема у меня получается такая
![alt text](https://github.com/darkzorro79/platform_project/raw/main/network_schema.png)
Предвижу вопросы про сеть с двумя интернетами, поясню
  все ноды имеют локальные IP адреса по которым общается kubernetes, интернет с белыми IP адресами(дополнительными адаптерами) есть только у Ingress нод, остальные ноды имеют интернет через NAT
Так же локальное окружение находится в домене AD и локальные ресурсы типа DNS и т.п. ростут от туда.

Kubernetes наливаю с помощью Ansible kubespray манифестов, + в качестве среды запуска контейнеров выбираю ванильный docker - по причине того, что репозиторий elasticsearch для datahub не доступен из России
и принял решение сконфигурировать pull-инг докер image-ей через socks5-proxy, поскольку с остальными средами дело не имел, в таком контексте - работаю с docker.
Схема kubernetes получается такая.
![alt text](https://github.com/darkzorro79/platform_project/raw/main/kuber_schema.png)

## 1. Ansible or Terraform deploy vm in ESXi (vCenter)
Покажу на данный момент Ansible
c ESXi и/или vCenter работает модуль vmware_guest - проставим его перед деплоем.

playbook вида 
```yml
---
- name: Create a new virtual machine from template
  hosts: localhost
  gather_facts: no
  vars:
    vcenter_hostname: "10.190.26.45"
    vcenter_username: "administrator@vsphere.local"
    vcenter_password: ""
    vm_template_name: "CentOS8_k8s_template"
    vm_name: "k8s-ingress1"
    vm_datastore: "flash3"
    vm_network_name: "LAN-136"
    datacenter: "Datacenter"
    guest_domain: "kropalik.local"
    vm_folder: "k8s"
  tasks:
    - name: Create a new virtual machine from template
      vmware_guest:
        hostname: "{{ vcenter_hostname }}"
        username: "{{ vcenter_username }}"
        password: "{{ vcenter_password }}"
        validate_certs: no
        datacenter: "{{ datacenter }}"
        state: poweredon
        guest_id: centos8_64Guest
        folder: "{{ vm_folder }}"
        name: "{{ vm_name }}"
        disk:
        - size_gb: 50
          type: thin
          datastore: "{{ vm_datastore }}"
        networks:
          - name: "{{ vm_network_name }}"
            ip: 192.168.136.120
            netmask: 255.255.255.0
            gateway: 192.168.136.1
            dns_servers:
              - 192.168.136.10
            start_connected: yes
        wait_for_ip_address: true
        wait_for_ip_address_timeout: 60
        customization:
          existing_vm: true
          hostname: "{{ vm_name }}"
          domain: "{{ guest_domain }}"
          dns_servers:
            - 192.168.136.10
          dns_suffix:
            - kropalik.local
          script_text: |
            #!/bin/bash
            touch /tmp/touch-from-playbook
        template: "{{ vm_template_name }}"
      delegate_to: localhost
      register: deploy_vm

```
в итоге получаем 
![alt text](https://github.com/darkzorro79/platform_project/raw/main/k8s-in-vcs.png)


## 2. Ansible kubespray - install kubernetes
По мимо случае о выборе ванильного докера в пункте 0. что ещё имеем интересного в inventory:
1. у ingress нод есть белые IP - пропишем их, не забываем, что ingress не имеет default gateway на внутренним интерфесе
```yml
[all]
k8s-master1 ansible_host=192.168.136.100  etcd_member_name=etcd-1
k8s-master2 ansible_host=192.168.136.101  etcd_member_name=etcd-2
k8s-master3 ansible_host=192.168.136.102  etcd_member_name=etcd-3
k8s-worker1  ansible_host=192.168.136.110  
k8s-worker2  ansible_host=192.168.136.111
k8s-worker3  ansible_host=192.168.136.112
k8s-ingress1  ansible_host=91.219.24.173   ip=192.168.136.120 
k8s-ingress2  ansible_host=91.219.27.191   ip=192.168.136.121 
```
2. Выделим ноды ingress и worker
```yml
[all:vars]
ansible_user=root
# supplementary_addresses_in_ssl_keys='["192.168.136.100","192.168.136.101","192.168.136.102"]'


[kube_control_plane]
k8s-master1
k8s-master2
k8s-master3

[etcd]
k8s-master1
k8s-master2
k8s-master3

[kube_node]
k8s-worker1
k8s-worker2
k8s-worker3
k8s-ingress1
k8s-ingress2

[kube-worker]
k8s-worker1
k8s-worker2
k8s-worker3

[kube-ingress]
k8s-ingress1
k8s-ingress2

[k8s_cluster:children]
kube_control_plane
kube_node
```
На ingress нодах нам не надо запускать нагрузку, только сам ingress-controller пропишем в файле kube-ingress.yml
```yml
node_labels:
  node-role.kubernetes.io/ingress: "true"
node_taints:
  - "node-role.kubernetes.io/ingress=:NoSchedule"
```
А для worker нод соответсвенно kube-worker.yml
```yml
node_labels:
  node-role.kubernetes.io/worker: "true"
```

3. В addon-ах включаем:

helm_enabled: true  - все наши проекты в helm chart-ах, за нас его включит Ansible

local_path_provisioner_enabled: true   - чтобы не морочиться с более сложными файловыми и блочными системами - для курсовой будет вполне достаточно.

ingress_nginx_enabled: true - для них мы уже создали целых 2 vm

cert_manager_enabled: true - чтобы не морочиться, за нас его поставит Ansible - а ClusterIssuer мы прикрутим руками.


## 3. Install Datahub
Однако помним про ClusterIssuer давайте его запилим, чтобы на будущее не морочиться с сертификатами
cluster-issuer-prod.yaml
```yml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@kropalik.ru
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
    - http01:
        ingress:
          class: nginx
```
cluster-issuer-stage.yaml
```yml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@kropalik.ru
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
```
применим их в дефолтный namespace
и проверим

```console
kubectl get clusterissuers.cert-manager.io
NAME                     READY   AGE
letsencrypt-production   True    26h
letsencrypt-staging      True    26h
```


Основная инструкция здесь https://datahubproject.io/docs/deploy/kubernetes/

из отклонений от оригинала выделю следущее:
после создания namespace и секретов
```console
kubectl create namespace datahub
namespace/datahub created
```

```console
./secrets.sh
secret/mysql-secrets created
secret/neo4j-secrets created
```
меняем в values.yaml на existingPasswordSecret: neo4j-secrets так как секреты уже есть, и есть откуда их считать.

```console
helm install prerequisites datahub/datahub-prerequisites --values values.yaml --wait --namespace=datahub
NAME: prerequisites
LAST DEPLOYED: Wed Apr 19 13:17:54 2023
NAMESPACE: datahub
STATUS: deployed
REVISION: 1
```


меняем в values.yaml на
  ingress:
    enabled: true
    hosts:
      - host: datahub.otservice.ru
        redirectPaths:
          - path: /
            name: ssl-redirect
            port: use-annotation
        paths:
          - /
        tls:
          - secretsName: datahub-datahub-frontend
            hosts:
              - datahub.otservice.ru

а так же увеличим время ожидания на пробах c 60 сек до 120, чтобы избежать ошибок
```console
grep -R "120" .
./charts/datahub-frontend/values.yaml:  initialDelaySeconds: 120
./charts/datahub-frontend/values.yaml:  initialDelaySeconds: 120
./charts/datahub-gms/values.yaml:  initialDelaySeconds: 120
./charts/datahub-gms/values.yaml:  initialDelaySeconds: 120
./charts/datahub-mae-consumer/values.yaml:  initialDelaySeconds: 120
./charts/datahub-mae-consumer/values.yaml:  initialDelaySeconds: 120
./charts/datahub-mce-consumer/values.yaml:  initialDelaySeconds: 120
./charts/datahub-mce-consumer/values.yaml:  initialDelaySeconds: 120
```

```console
helm install datahub datahub/datahub --values values.yaml --wait --namespace=datahub
Release "datahub" has been upgraded. Happy Helming!
NAME: datahub
LAST DEPLOYED: Wed Apr 19 14:55:16 2023
NAMESPACE: datahub
STATUS: deployed
REVISION: 1
TEST SUITE: None

```


```console
kubectl get po -n datahub
NAME                                                READY   STATUS      RESTARTS   AGE
datahub-acryl-datahub-actions-f7b9c4977-v2hx9       1/1     Running     0          39m
datahub-datahub-frontend-f6fd5996f-wd9hc            1/1     Running     0          39m
datahub-datahub-gms-5b8b89574d-r65bh                1/1     Running     0          39m
datahub-datahub-system-update-job-hcn9j             0/1     Completed   0          40m
datahub-elasticsearch-setup-job-n7dfz               0/1     Completed   0          42m
datahub-kafka-setup-job-4ccmq                       0/1     Completed   0          42m
datahub-mysql-setup-job-5kx4f                       0/1     Completed   0          40m
elasticsearch-master-0                              1/1     Running     0          54m
elasticsearch-master-1                              1/1     Running     0          54m
elasticsearch-master-2                              1/1     Running     0          54m
prerequisites-cp-schema-registry-5f89dd4974-7mwxh   2/2     Running     0          54m
prerequisites-kafka-0                               1/1     Running     0          54m
prerequisites-mysql-0                               1/1     Running     0          54m
prerequisites-zookeeper-0                           1/1     Running     0          54m
```
совпадает с окончательной таблицей подов с мануалом.

проверяем https://datahub.otservice.ru/

всё огонь!

## 4. CI/CD + logging
Ставим ArgoCD
Основная инструкция здесь: https://argo-cd.readthedocs.io/en/stable/

```console
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```
как видим, установка происходит из файла, в котором нет ничего про ingress
Запилим его в ручную
```yml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-production"
    kubernetes.io/ingress.class: nginx
    kubernetes.io/tls-acme: "true"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  rules:
  - host: argocd.otservice.ru
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              name: https
  tls:
  - hosts:
    - argocd.otservice.ru
    secretName: argocd-secret
```

https://argocd.otservice.ru  - проверяем - всё в норме!

Теперь настроим ArgoCD до нашего приватного репозитория с помощью SSH ключа, так как в helm chart-e Loghous содержиться пароль.

Loghous

Скачиваем проект с https://github.com/flant/loghouse.git
Редакатируем helm chart - меняем пароль и прописывем данные для ingress

```yml
auth: --------------------------

# Settings for ingress
ingress:
  enable: true
  enable_https: true
  clickhouse:
    host: clickhouse.otservice.ru
    path: "/"
    tls_secret_name: clickhouse
#   ingressClass: nginx
#   tls_issuer: letsencrypt
#   tls_issuer_kind: ClusterIssuer
    annotations:
#     traefik.frontend.passHostHeader: "true"
     cert-manager.io/cluster-issuer: "letsencrypt-production"
  loghouse:
    host: loghouse.otservice.ru
    path: "/"
    tls_secret_name: loghouse
#   ingressClass: nginx
#   tls_issuer: letsencrypt
#   tls_issuer_kind: ClusterIssuer
    annotations:
#     traefik.frontend.passHostHeader: "true"
      cert-manager.io/cluster-issuer: "letsencrypt-production"
  tabix:
    host: tabix.otservice.ru
    path: "/"
    tls_secret_name: tabix
#   ingressClass: traefik
#   tls_issuer: letsencrypt
#   tls_issuer_kind: ClusterIssuer
    annotations:
#     traefik.frontend.passHostHeader: "true"
      cert-manager.io/cluster-issuer: "letsencrypt-production"
```

Теперь постим всё в github и создаём Applications в ArgoCD
```yml
project: infrastructure
source:
  repoURL: 'git@github.com:darkzorro79/loghouse.git'
  path: charts/loghouse
  targetRevision: HEAD
destination:
  server: 'https://kubernetes.default.svc'
  namespace: loghouse
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
```
после подключения Application синхронизируется и выкатывает нам Loghous
![alt text](https://github.com/darkzorro79/platform_project/raw/main/Loghouse-in-argoCD.png)

Проверяем https://loghouse.otservice.ru/query?seek_to=24+hours+ago&time_from=&time_to=&query=&per_page=&time_format=seek_to - всё работает!

##5. Install monitoring
Для мониторинга будем использоваеть kube-prometheus-stack - весь полный набор в одном helm chart-е 
нам остаётся только его спуллить и подправить ingress-ы под наш домен

```console
helm pull prometheus-community/kube-prometheus-stack
```
разворачиваем kube-prometheus-stack-45.18.0.tgz и правим values.yaml

```yml
grafana:
  enabled: true
  namespaceOverride: ""

  ## ForceDeployDatasources Create datasource configmap even if grafana deployment has been disabled
  ##
  forceDeployDatasources: false

  ## ForceDeployDashboard Create dashboard configmap even if grafana deployment has been disabled
  ##
  forceDeployDashboards: false

  ## Deploy default dashboards
  ##
  defaultDashboardsEnabled: true

  ## Timezone for the default dashboards
  ## Other options are: browser or a specific timezone, i.e. Europe/Luxembourg
  ##
  defaultDashboardsTimezone: utc

  adminPassword: 

  rbac:
    ## If true, Grafana PSPs will be created
    ##
    pspEnabled: false

  ingress:
    ## If true, Grafana Ingress will be created
    ##
    enabled: true

    ## IngressClassName for Grafana Ingress.
    ## Should be provided if Ingress is enable.
    ##
    # ingressClassName: nginx

    ## Annotations for Grafana Ingress
    ##
    annotations:
       kubernetes.io/ingress.class: nginx
       kubernetes.io/tls-acme: "true"
       cert-manager.io/cluster-issuer: "letsencrypt-production"

    ## Labels to be added to the Ingress
    ##
    labels: {}

    ## Hostnames.
    ## Must be provided if Ingress is enable.
    ##
    # hosts:
    #   - grafana.domain.com
    hosts:
      - grafana.otservice.ru

    ## Path for grafana ingress
    path: /

    ## TLS configuration for grafana Ingress
    ## Secret must be manually created in the namespace
    ##
    tls:
      - secretName: grafana-general-tls
        hosts:
        - grafana.otservice.ru
```

выкатываем и настраиваем Dashboard в Grafana
```console
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace --values kube-prometheus-stack/values.yam
```
проверяем
https://grafana.otservice.ru/d/Y4fD-LE4z/node-exporter-nodes?orgId=1&refresh=30s&var-datasource=default&var-instance=192.168.136.110:9100&from=now-2d&to=now


-----------
Спасибо за внимание.
