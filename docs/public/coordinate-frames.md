# Coordinate frames

**Shared session time; independent ARKit spatial frames.** Receiver timing
coordinates the Hand (`wrist_umi`) and Ego (`ego`) streams. Each phone keeps its
own device-local ARKit capture frame. Matching timestamps and a common
gravity-up/initial-camera-forward direction convention do not establish a
shared origin or a Hand-to-Ego transform.

## Hand-local physical TCP motion

The physical TCP is the tool-center point defined by the matching mount profile.
Here, `A_T_C(t)` is the camera pose in its device-local capture-reference frame,
and `C_T_U` is the versioned camera-to-physical-TCP transform. With one coherent
anchor:

```text
U0_T_U(t) = inverse(C_T_U) * inverse(A_T_C(0)) * A_T_C(t) * C_T_U
```

The first accepted normal-tracking sample is the complete identity transform.
Translations are in metres; the TCP axis convention is
`x_forward_y_left_z_up`. Transforms must be proper rigid transforms: reflected
or materially distorted rotations fail validation.

Robot retargeting additionally requires a validated, versioned robot start
forward-kinematics transform `B0_T_U0`:

```text
B0_T_U(t) = B0_T_U0 * U0_T_U(t)
```

This equation specifies the coordinate contract. The private processing and
robot-retargeting workflow is not shipped in the public source release.
Legacy `world_T_tcp` is diagnostic-only and must never be used as coordinate
truth. No Ego-to-Hand transform is derived by this equation.

## Intrinsics and calibration boundary

iOS retains per-frame ARKit camera intrinsics, image-preprocessing intrinsics,
the numeric experimental camera approximation, and the project-owned physical
TCP profile. The approximation is not laboratory calibration and its distortion
coefficients start at zero. A TCP profile applies only to its matching physical
assembly. Successful capture or upload does not independently validate camera
calibration, mount geometry, or downstream robot motion.

See the [capture-package contract](../../contracts/capture-package.md) for
orientation metadata and integrity requirements, and
[known limitations](known-limitations.md) for the public validation boundary.
