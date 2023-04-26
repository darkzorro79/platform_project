kubectl port-forward --address 0.0.0.0 `kubectl get po -n datahub | grep datahub-datahub-frontend | awk '{print $1}'` 9002:9002 -n datahub
