install:
	helm upgrade --install argocd argo/argo-cd --version $(ARGOCD_CHART_VERSION) -n argocd
	kubectl get pods -n $(NS_DEMO)
