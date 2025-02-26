# Security-Profiles-Operator demo

This demo is meant to show the basic functionality of the operator for
deploying Seccomp profiles and SELinux policies.

# Demo prerequisites and setup

* Podman available

* SPO installed. After OpenShift 4.12+, the operator should be available
  from the included OperatorHub, before 4.12 GA, please follow [upstream instructions](https://github.com/kubernetes-sigs/security-profiles-operator/blob/main/installation-usage.md#openshift)
  You can also use the `install-resources.yaml` manifest in this repo.

* Run the `make setup` target. This will set up an appropriate namespace and
  the needed base profile.

# Instructions

Look at the target application in `main.go`. This app that we want to deploy is
quite simple. It merely is a go application that writes its logs to the
specific node. You can image a similar workload which would instead read the
nodes' logs and forward them to a secure location.

You'll note that the aforementioned `setup` target already uploaded it to its
appropriate namespace in OpenShift's image registry. Let's try to take it into
use!

```
oc apply -f 01-demo-pod-no-security.yaml
```

You'll notice that the workload failed. Let's take a look:

```
$ oc logs demo
Unable to open log file: open /log/demologs.log: permission denied
```

This is to be expected! Accessing a host is a privileged operation, and so, a
regular workload is not able to do this. We could simply set the `privileged`
flag in the pod's `securityContext` section to `true`. But we shouldn't do
this, as it would give too much access to the host itself...

First, let's restrict our workload to only be able to do what we expect it to
do! We can create a Seccomp profile so the application will only run the system
calls that we approve.

Let's take a look at the next workload and the seccomp profiles:

```
less seccompprofile.yaml
less baseprofile-runc.yaml
less 02-demo-pod-seccomp.yaml
```

There is a seccomp profile for this workload in `seccompprofile.yaml`.
Note that this profile inherits system calls from another profile
through the `baseProfileName` attribute. This base profile is in the
manifest named `baseprofile-runc.yaml`. We use a base profile and a
workload-specific profile to keep the workload profile neat and tidy. With
the current SPO version, the base profile must be created in the same
namespace as the workload specific profiles, although there are [upstream
issues](https://github.com/kubernetes-sigs/security-profiles-operator/issues/1313)
to make the handling of the base profiles easier.

Let's take it into use then!

```
oc delete pod demo
oc create -f baseprofile-runc.yaml
oc wait --for=condition=ready sp runc-v1.0.0
oc create -f seccompprofile.yaml
oc wait --for=condition=ready sp seccomp-demo
oc create -f 02-demo-pod-seccomp.yaml
```

As we can see, this workload is now running a little more restricted and
attackers will have a harder time doing something nasty with it. Because we are
a little afraid of SELinux, we gave it `spc_t` so we didn't have to come up
with a profile...

This was not a good idea, as an attacker can take that application into use and
write to other logs... for instance, the audit logs!

Let's look at a small scenario:

```
oc delete pod demo
oc create -f 03-demo-pod-badpod.yaml
```

This is restricted by Seccomp, but can now write to the host's audit folder...
That's because seccomp can only limit the system calls an application does
(e.g. write) but does not distinguish between where would the application
write to.
In this case we're not doing anything destructive, but a clever attacker
certainly could.

Let's see how SELinux can help us mitigate this. We already have a small
policy that would take care of this. Let's create the policy and wait for it
to become ready:

```
oc create -f selinuxprofile.yaml
oc wait --for=condition=ready --timeout=120s selinuxprofile errorlogger
```

As you can see, it wasn't as intimidating as we thought! And now our
application is not as unsafe as it used to be. Let's see how SELinux helps with
this:

```
oc delete pod demo-bad-pod
oc create -f 04-demo-pod-badpod.yaml
```

We'll see now that if the pods attempts to write to the wrong logs, it'll get a
denial coming from SELinux.

Let's now deploy the application with the appropriate security profiles set:

```
oc create -f 05-demo-secure.yaml
```

Our application is now happily running with appropriate security set!

## SELinux profile recording

Even though applying the SELinux policy from an existing manifest already
solves the problem of installing the policy, creating the policy in the
first place might not be trivial. For that, SPO offers a feature called
profile recording that is able to track the application and create profiles
based on what it does.

For SELinux, the feature tails the audit.log and watches for potential
AVC denials while the application being recorded is running with a special
permissive profile.

Therefore we need to enable the feature first:
```
oc patch spod spod -p '{"spec":{"enableLogEnricher":true}}' --type=merge -nsecurity-profiles-operator
```

Then we create a namespace to record the application at. This namespace is labeled
with `spo.x-k8s.io/enable-recording=` to make sure that SPO knows that it's OK
to inject the permissive recording policy into workloads in this namespace:
```
oc create -f record-ns.yaml
oc project record-demo
oc label ns record-demo security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged --overwrite=true
```

We're ready to start recording. This is done by creating a `ProfileRecording`
object that will match the labels of the application:
```
oc create -f profilerecording.yaml
```

Then we create the app to be recorded. This is the same manifest as the very first
one, so no policies are used by this point:
```
oc create -f 06-demo-pod-record.yaml
```

We let the app run so that the recorder catches all the actions the app is doing
and then delete the application first and then the recording:
```
oc delete po demo
oc delete profilerecording test-recording
```

Now we should have a policy ready:
```
oc get selinuxprofile test-recording-demo -oyaml
```
It takes a bit to install the policy:
```
oc wait --for=condition=ready --timeout=120s selinuxprofile test-recording-demo
```

And we can verify the policy works by taking it into use in the next example:
```
oc create -f 07-demo-pod-recorded.yaml
```
