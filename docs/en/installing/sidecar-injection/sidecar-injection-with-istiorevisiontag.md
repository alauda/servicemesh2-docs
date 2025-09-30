---
weight: 30
---

# Enabling sidecar injection with IstioRevisionTag resource

If your revision name is not `default`, you can still use the `istio-injection=enabled` label. To do so, you must first create an `IstioRevisionTag` resource named `default` that points to your `Istio` resource.

## Reference

- [IstioRevisionTag resource](https://github.com/istio-ecosystem/sail-operator/blob/main/docs/README.adoc#istiorevisiontag-resource) (Sail Operator documentation)

## Prerequisites

- The Alauda Service Mesh v2 Operator has been installed, an `Istio` resource is created, and Istio has been deployed by the Operator.
- An `IstioCNI` resource has been created, and the required `IstioCNI` pods are deployed by the Operator.
- The namespaces intended to be part of the mesh exist and can be discovered by the Istio control plane.
- Optional: Workloads for the mesh are already deployed. In these examples, the Bookinfo application exists in the `bookinfo` namespace, but sidecar injection (as described in step 2) is not yet configured. Refer to "[Deploying the Bookinfo application](../installing-service-mesh/application-deployment/deploying-the-bookinfo-application.mdx)" for further information.

## Procedure

1.  To find the name of your `Istio` resource, execute the following command:

    ```shell
    kubectl get istio
    ```

    **Example output**

    ```shell
    NAME      NAMESPACE      PROFILE   REVISIONS   READY   IN USE   ACTIVE REVISION   STATUS    VERSION   AGE
    default   istio-system             1           1       0        default-v1-26-3   Healthy   v1.26.3   37s
    ```

    In this case, the `Istio` resource is named `default`, but its underlying revision is `default-v1-26-3`.

2.  Define the `IstioRevisionTag` resource in a YAML file:

    **Example `IstioRevisionTag` Resource YAML**

    ```yaml
    apiVersion: sailoperator.io/v1
    kind: IstioRevisionTag
    metadata:
      name: default
    spec:
      targetRef:
        kind: Istio
        name: default
    ```

3.  Apply the `IstioRevisionTag` resource using this command:

    ```shell
    kubectl apply -f istioRevisionTag.yaml
    ```

4.  Confirm the successful creation of the `IstioRevisionTag` resource with the following command:

    ```shell
    kubectl get istiorevisiontags.sailoperator.io
    ```

    **Example output**

    ```shell
    NAME      STATUS    IN USE   REVISION          AGE
    default   Healthy   True     default-v1-26-3   15s
    ```

    As shown in the example, the new tag now references your active revision, `default-v1-26-3`. Now you can use the `istio-injection=enabled` label as if your revision was called `default`.

5.  Check that the pods are running without sidecars by executing the command below. All existing workloads in the target namespace should display `1/1` in the `READY` containers column.

    ```shell
    kubectl get pods -n bookinfo
    ```

    **Example output**

    ```shell
    NAME                              READY   STATUS    RESTARTS   AGE
    details-v1-85c7fcfd5b-fdx4q       1/1     Running   0          5m48s
    productpage-v1-775ffc67d8-89n5c   1/1     Running   0          5m48s
    ratings-v1-6c79fdf684-cdkzc       1/1     Running   0          5m48s
    reviews-v1-685fb87cb6-pgzm5       1/1     Running   0          5m48s
    reviews-v2-76c4659bc6-lgtp4       1/1     Running   0          5m48s
    reviews-v3-f7b4c8678-x2hnp        1/1     Running   0          5m48s
    ```

6.  Add the injection label to the `bookinfo` namespace with the following command:

    ```shell
    kubectl label namespace bookinfo istio-injection=enabled
    ```

    **Example output**

    ```shell
    namespace/bookinfo labeled
    ```

7.  To activate sidecar injection, trigger a redeployment of the workloads in the `bookinfo` namespace by running this command:

    ```shell
    kubectl -n bookinfo rollout restart deployments
    ```

## Verification

1.  Check the rollout's success by running the command below and confirming that the newly created pods show `2/2` containers in the `READY` column:

    ```shell
    kubectl get pods -n bookinfo
    ```

    **Example output**

    ```shell
    NAME                              READY   STATUS    RESTARTS   AGE
    details-v1-d964f49cb-bdlwn        2/2     Running   0          38s
    productpage-v1-79fbc54dfb-wbtf2   2/2     Running   0          38s
    ratings-v1-6f4bf85f96-glkg9       2/2     Running   0          38s
    reviews-v1-57d48b8c6b-hlfbt       2/2     Running   0          38s
    reviews-v2-6d65c788d4-q98pl       2/2     Running   0          38s
    reviews-v3-6cf5df6bb6-phnj9       2/2     Running   0          38s
    ```
