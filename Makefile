IMAGE:=demo:latest
NAMESPACE:=demo

.PHONY: build
build: demo

demo: main.go
	go build -o demo main.go

.PHONY: image
image:
	podman build --arch ppc64le -t $(IMAGE) -f Dockerfile .

.PHONY: setup
setup: image openshift-user
	@oc apply -f ns.yaml
	@oc label ns demo --overwrite=true security.openshift.io/scc.podSecurityLabelSync=false
	@oc label ns demo --overwrite=true pod-security.kubernetes.io/enforce=privileged
	@oc project $(NAMESPACE)
	@echo "Exposing the default route to the image registry"
	@oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
	@echo "Pushing image $(IMAGE) to the image registry"
	@IMAGE_REGISTRY_HOST=$$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}'); \
		podman login --tls-verify=false -u $(OPENSHIFT_USER) -p $(shell oc whoami -t) $${IMAGE_REGISTRY_HOST}; \
		podman push --tls-verify=false $(IMAGE) $${IMAGE_REGISTRY_HOST}/$(NAMESPACE)/$(IMAGE)
	@echo "Creating base seccomp profile"
	@oc apply -f baseprofile-runc.yaml

.PHONY: openshift-user
openshift-user:
ifeq ($(shell oc whoami 2> /dev/null),kube:admin)
	$(eval OPENSHIFT_USER = kubeadmin)
else
	$(eval OPENSHIFT_USER = $(shell oc whoami))
endif
