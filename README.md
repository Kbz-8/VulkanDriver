# Ape Vulkan ICD <a href="https://git.kbz8.me/kbz_8/VulkanDriver/actions?workflows=Build.yml"><img src="https://git.kbz8.me/kbz_8/VulkanDriver/actions/workflows/Build.yml/badge.svg"></a> <a href="https://git.kbz8.me/kbz_8/VulkanDriver/actions?workflows=Test.yml"><img src="https://git.kbz8.me/kbz_8/VulkanDriver/actions/workflows/Test.yml/badge.svg"></a>

<img align="right" width="250px" src="./logo.png"/>

For I feel as an ape, smiting sticks together in the vain hope of forging a driver.

Here lies the source code of a rather calamitous attempt at the Vulkan specification, shaped into an Installable Client Driver all written in Zig.

It was forged for my own learning and amusement alone. Pray, do not wield it in any earnest project, lest thy hopes and frame rates both find themselves entombed.

## Purpose

To understand Vulkan - not as a humble API mere mortals call upon, but as a labyrinthine system where one may craft a driver by hand.
It does not seek to produce a performant or production-worthy driver. \
*The gods are merciful, but not that merciful.*

## Soft [software implementation]

Soft be a software implementation of the Vulkan specification, abiding within this driver's own codebase.\
It maketh use of a bespoke [SPIR-V interpreter](https://git.kbz8.me/kbz_8/SPIRV-Interpreter) and renderer, by whose workings its labours are carried forth.

### Build

If thou art truly determined:
```
zig build soft
```

Then ensure thy Vulkan loader is pointed toward the ICD manifest.
The precise ritual varies by system - consult the tomes of your operating system, or wander the web's endless mausoleum of documentation.

Use at your own risk. If thy machine shudders, weeps, or attempts to flee - know that it was warned.

#### Vulkan 1.0 specification
<details>
    <summary>
        The present standing of thy Vulkan 1.0 specification's implementation
    </summary>

\
⚠️ Implemented, yet perchance not fully tested nor proven conformant, but rather working in a manner most general to thee and thine.\
Assume thou that functions lacking in this array are, for now, not intended to be wrought.

Name                                             | Status
-------------------------------------------------|--------
vkAcquireNextImageKHR                            | ✅ Implemented
vkAllocateCommandBuffers                         | ✅ Implemented
vkAllocateDescriptorSets                         | ✅ Implemented
vkAllocateMemory                                 | ✅ Implemented
vkBeginCommandBuffer                             | ✅ Implemented
vkBindBufferMemory                               | ✅ Implemented
vkBindImageMemory                                | ✅ Implemented
vkCmdBeginQuery                                  | ✅ Implemented
vkCmdBeginRenderPass                             | ✅ Implemented
vkCmdBindDescriptorSets                          | ✅ Implemented
vkCmdBindIndexBuffer                             | ✅ Implemented
vkCmdBindPipeline                                | ✅ Implemented
vkCmdBindVertexBuffers                           | ✅ Implemented
vkCmdBlitImage                                   | ✅ Implemented
vkCmdClearAttachments                            | ✅ Implemented
vkCmdClearColorImage                             | ✅ Implemented
vkCmdClearDepthStencilImage                      | ✅ Implemented
vkCmdCopyBuffer                                  | ✅ Implemented
vkCmdCopyBufferToImage                           | ✅ Implemented
vkCmdCopyImage                                   | ✅ Implemented
vkCmdCopyImageToBuffer                           | ✅ Implemented
vkCmdCopyQueryPoolResults                        | ✅ Implemented
vkCmdDispatch                                    | ✅ Implemented
vkCmdDispatchIndirect                            | ✅ Implemented
vkCmdDraw                                        | ✅ Implemented
vkCmdDrawIndexed                                 | ✅ Implemented
vkCmdDrawIndexedIndirect                         | ✅ Implemented
vkCmdDrawIndirect                                | ✅ Implemented
vkCmdEndQuery                                    | ✅ Implemented
vkCmdEndRenderPass                               | ✅ Implemented
vkCmdExecuteCommands                             | ✅ Implemented
vkCmdFillBuffer                                  | ✅ Implemented
vkCmdNextSubpass                                 | ✅ Implemented
vkCmdPipelineBarrier                             | ✅ Implemented
vkCmdPushConstants                               | ✅ Implemented
vkCmdResetEvent                                  | ✅ Implemented
vkCmdResetQueryPool                              | ✅ Implemented
vkCmdResolveImage                                | ✅ Implemented
vkCmdSetBlendConstants                           | ✅ Implemented
vkCmdSetDepthBias                                | ⚙️ WIP
vkCmdSetDepthBounds                              | ⚙️ WIP
vkCmdSetEvent                                    | ✅ Implemented
vkCmdSetLineWidth                                | ⚙️ WIP
vkCmdSetScissor                                  | ✅ Implemented
vkCmdSetStencilCompareMask                       | ✅ Implemented
vkCmdSetStencilReference                         | ✅ Implemented
vkCmdSetStencilWriteMask                         | ✅ Implemented
vkCmdSetViewport                                 | ✅ Implemented
vkCmdUpdateBuffer                                | ✅ Implemented
vkCmdWaitEvents                                  | ✅ Implemented
vkCmdWriteTimestamp                              | ⚙️ WIP
vkCreateBuffer                                   | ✅ Implemented
vkCreateBufferView                               | ✅ Implemented
vkCreateCommandPool                              | ✅ Implemented
vkCreateComputePipelines                         | ✅ Implemented
vkCreateDescriptorPool                           | ✅ Implemented
vkCreateDescriptorSetLayout                      | ✅ Implemented
vkCreateDevice                                   | ✅ Implemented
vkCreateEvent                                    | ✅ Implemented
vkCreateFence                                    | ✅ Implemented
vkCreateFramebuffer                              | ✅ Implemented
vkCreateGraphicsPipelines                        | ✅ Implemented
vkCreateImage                                    | ✅ Implemented
vkCreateImageView                                | ✅ Implemented
vkCreateInstance                                 | ✅ Implemented
vkCreatePipelineCache                            | ⚙️ WIP
vkCreatePipelineLayout                           | ✅ Implemented
vkCreateQueryPool                                | ✅ Implemented
vkCreateRenderPass                               | ✅ Implemented
vkCreateSampler                                  | ✅ Implemented
vkCreateSemaphore                                | ⚙️ WIP
vkCreateShaderModule                             | ✅ Implemented
vkCreateSwapchainKHR                             | ✅ Implemented
vkCreateWaylandSurfaceKHR                        | ✅ Implemented
vkCreateWin32SurfaceKHR                          | ⚙️ WIP
vkCreateXcbSurfaceKHR                            | ⚙️ WIP
vkCreateXlibSurfaceKHR                           | ⚙️ WIP
vkDestroyBuffer                                  | ✅ Implemented
vkDestroyBufferView                              | ✅ Implemented
vkDestroyCommandPool                             | ✅ Implemented
vkDestroyDescriptorPool                          | ✅ Implemented
vkDestroyDescriptorSetLayout                     | ✅ Implemented
vkDestroyDevice                                  | ✅ Implemented
vkDestroyEvent                                   | ✅ Implemented
vkDestroyFence                                   | ✅ Implemented
vkDestroyFramebuffer                             | ✅ Implemented
vkDestroyImage                                   | ✅ Implemented
vkDestroyImageView                               | ✅ Implemented
vkDestroyInstance                                | ✅ Implemented
vkDestroyPipeline                                | ✅ Implemented
vkDestroyPipelineCache                           | ✅ Implemented
vkDestroyPipelineLayout                          | ✅ Implemented
vkDestroyQueryPool                               | ✅ Implemented
vkDestroyRenderPass                              | ✅ Implemented
vkDestroySampler                                 | ✅ Implemented
vkDestroySemaphore                               | ✅ Implemented
vkDestroyShaderModule                            | ✅ Implemented
vkDestroySurfaceKHR                              | ✅ Implemented
vkDestroySwapchainKHR                            | ✅ Implemented
vkDeviceWaitIdle                                 | ✅ Implemented
vkEndCommandBuffer                               | ✅ Implemented
vkEnumerateDeviceExtensionProperties             | ✅ Implemented
vkEnumerateDeviceLayerProperties                 | ✅ Implemented
vkEnumerateInstanceExtensionProperties           | ✅ Implemented
vkEnumerateInstanceLayerProperties               | ✅ Implemented
vkEnumeratePhysicalDevices                       | ✅ Implemented
vkFlushMappedMemoryRanges                        | ✅ Implemented
vkFreeCommandBuffers                             | ✅ Implemented
vkFreeDescriptorSets                             | ✅ Implemented
vkFreeMemory                                     | ✅ Implemented
vkGetBufferMemoryRequirements                    | ✅ Implemented
vkGetDeviceMemoryCommitment                      | ⚙️ WIP
vkGetDeviceProcAddr                              | ✅ Implemented
vkGetDeviceQueue                                 | ✅ Implemented
vkGetEventStatus                                 | ✅ Implemented
vkGetFenceStatus                                 | ✅ Implemented
vkGetImageMemoryRequirements                     | ✅ Implemented
vkGetImageSparseMemoryRequirements               | ❎ Unsupported
vkGetImageSubresourceLayout                      | ✅ Implemented
vkGetInstanceProcAddr                            | ✅ Implemented
vkGetPhysicalDeviceFeatures                      | ✅ Implemented
vkGetPhysicalDeviceFormatProperties              | ✅ Implemented
vkGetPhysicalDeviceImageFormatProperties         | ✅ Implemented
vkGetPhysicalDeviceMemoryProperties              | ✅ Implemented
vkGetPhysicalDeviceProperties                    | ✅ Implemented
vkGetPhysicalDeviceQueueFamilyProperties         | ✅ Implemented
vkGetPhysicalDeviceSparseImageFormatProperties   | ❎ Unsupported
vkGetPhysicalDeviceSurfaceCapabilitiesKHR        | ✅ Implemented
vkGetPhysicalDeviceSurfaceFormatsKHR             | ✅ Implemented
vkGetPhysicalDeviceSurfacePresentModesKHR        | ✅ Implemented
vkGetPhysicalDeviceSurfaceSupportKHR             | ✅ Implemented
vkGetPhysicalDeviceWaylandPresentationSupportKHR | ✅ Implemented
vkGetPhysicalDeviceWin32PresentationSupportKHR   | ⚙️ WIP
vkGetPhysicalDeviceXcbPresentationSupportKHR     | ⚙️ WIP
vkGetPhysicalDeviceXlibPresentationSupportKHR    | ⚙️ WIP
vkGetPipelineCacheData                           | ⚙️ WIP
vkGetQueryPoolResults                            | ⚙️ WIP
vkGetRenderAreaGranularity                       | ✅ Implemented
vkGetSwapchainImagesKHR                          | ✅ Implemented
vkInvalidateMappedMemoryRanges                   | ✅ Implemented
vkMapMemory                                      | ✅ Implemented
vkMergePipelineCaches                            | ⚙️ WIP
vkQueueBindSparse                                | ❎ Unsupported
vkQueuePresentKHR                                | ✅ Implemented
vkQueueSubmit                                    | ✅ Implemented
vkQueueWaitIdle                                  | ✅ Implemented
vkResetCommandBuffer                             | ✅ Implemented
vkResetCommandPool                               | ✅ Implemented
vkResetDescriptorPool                            | ✅ Implemented
vkResetEvent                                     | ✅ Implemented
vkResetFences                                    | ✅ Implemented
vkResetQueryPool                                 | ✅ Implemented
vkSetEvent                                       | ✅ Implemented
vkUnmapMemory                                    | ✅ Implemented
vkUpdateDescriptorSets                           | ✅ Implemented
vkWaitForFences                                  | ✅ Implemented
</details>

[Here](https://vulkan-driver.kbz8.me/cts/soft/) shalt thou find a most meticulous account of the Vulkan 1.0 conformance trials, set forth for thy scrutiny.

## License

Released unto the world as MIT for study, experimentation, and the occasional horrified whisper.
Do with it as thou wilt, but accept the consequences as thine own.

## Mirrors

This codebase is maintained chiefly upon [mine own Git forge](https://git.kbz8.me/kbz_8/VulkanDriver), though thou may also find an active mirror upon [GitHub](https://github.com/Kbz-8/VulkanDriver).
