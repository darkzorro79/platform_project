# platform_project
## Проектная работа по kubernetes

### 0. В курсовой работе разверну микросервисный проект https://datahubproject.io/
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

1. Ansbile or Terraform deploy vm in ESXi (vCenter)


### 2. Ansible kubespray - install kubernetes
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

