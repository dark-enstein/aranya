
meta_template:
	helm template --debug \
		clusterdos \
		metadeployment \
		--set clusterdos.ref=dev \
		--set kubeStateMetrics.enabled=true \
		--set alloy.enabled=true \
		--set gitapps.certmanager.enabled=true \
		--set gitapps.crossplane.enabled=true \
		--set gitapps.kubemetrics.enabled=true \
		--set gitapps.rook.enabled=true \
		--set gitapps.tailscale.enabled=true \
		--set gitapps.traefik.enabled=true

gitapps_template:
	helm template --debug \
		clusterdos \
		metadeployment \
		--set clusterdos.ref=v0.0.0 \
		--set gitapps.vllm.enabled=true \
		--set gitapps.vllm.secret.name=asdf

vllm_template:
	cd gitapps; \
	helm template --debug \
		clusterdos-vllm \
		vllm


test: meta_template
