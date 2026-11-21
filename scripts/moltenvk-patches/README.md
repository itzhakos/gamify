# MoltenVK patches

Applied by `scripts/build-winecx-full-deps.sh` (section 5) to the MoltenVK 1.4.2
release tarball (`*.patch`, in the source tree) and to the SPIRV-Cross it pins
(`spirv-cross/*.patch`, in `External/SPIRV-Cross` after `fetchDependencies --none`).
They came from Wolfenstein II: The New Colossus (idTech 6.5, Vulkan only), which
quit at `vkCreateDevice` and then failed shaders and pipelines.

| Patch | Why |
|---|---|
| `0001-advertise-shaderCullDistance` | The game requires `shaderCullDistance` (the 39th flag in `VkPhysicalDeviceFeatures`) or `vkCreateDevice` returns `VK_ERROR_FEATURE_NOT_PRESENT`. Metal has no cull distance. SPIRV-Cross writes `gl_CullDistance` as plain `[[user(cullN)]]` outputs, so the shaders compile and nothing is culled. CrossOver's MoltenVK advertises it too (for DXVK). |
| `0002-pipeline-cache-uuid-patch-level` | `pipelineCacheUUID` is only MVK version + GPU + OS. A pipeline cache a game saved with an older build would bring back MSL that the other patches here fix. The last 4 bytes now hold a patch level (`0x4352nnnn`). **Bump it whenever a patch changes the generated MSL.** |
| `0003-feed-unprovided-vertex-attributes` | A vertex shader reads an input location that the pipeline's vertex input state doesn't describe. Vulkan drivers accept that (the value is undefined). Metal says "Vertex attribute m_21(0) is missing from the vertex descriptor" and the pipeline fails. Wolfenstein II's are in pipelines with an empty vertex input state. Each such active attribute is fed at offset 0 with a 1-byte format of its class: from a vertex buffer the pipeline already uses, or else from a 16-byte zero buffer (MVKDevice::getPlaceholderVertexMTLBuffer) bound at binding 0's Metal slot. That slot is now always reserved (one fewer implicit-buffer slot for pipelines without vertex buffers). One `[mvk-warn]` per attribute. |
| `spirv-cross/0001-helper-invocation-bare-kill-blocks` | `error: use of undeclared identifier 'gl_HelperInvocation'` in fragment shaders that `discard` inside a helper function. The check that passes `gl_HelperInvocation` to a function with an `OpKill` block ran once per instruction. A block holding only `OpKill` has no instructions, so the function never got the argument. It now runs once per block. Also present in upstream SPIRV-Cross main (2026-11). |

The deps script builds MoltenVK only when `runtimes/winecx-full/lib/libMoltenVK.dylib` is missing.
To rebuild after changing a patch: remove that dylib and `build/x86_64-full/moltenvk`, then run
`scripts/build-winecx-full-deps.sh`.
