# Stroll Vulkan ICD <a href="https://git.kbz8.me/kbz_8/VulkanDriver/actions?workflows=Build.yml"><img src="https://git.kbz8.me/kbz_8/VulkanDriver/actions/workflows/Build.yml/badge.svg"></a> <a href="https://git.kbz8.me/kbz_8/VulkanDriver/actions?workflows=Test.yml"><img src="https://git.kbz8.me/kbz_8/VulkanDriver/actions/workflows/Test.yml/badge.svg"></a>

<img align="right" src="https://matthew.kerwin.net.au/blog_files/kappa"/>

A driver as slow as Lance Stroll.

Here lies the source code of a rather calamitous attempt at the Vulkan specification, shaped into an Installable Client Driver for a software-based renderer, all written in Zig.

It was forged for my own learning and amusement alone. Pray, do not wield it in any earnest project, lest thy hopes and frame rates both find themselves entombed.

## Purpose

To understand Vulkan - not as a humble API mere mortals call upon, but as a labyrinthine system where one may craft a driver by hand.
It does not seek to produce a performant or production-worthy driver. \
*The gods are merciful, but not that merciful.*

## Build

If thou art truly determined:
```
zig build
```

Then ensure thy Vulkan loader is pointed toward the ICD manifest.
The precise ritual varies by system - consult the tomes of your operating system, or wander the web's endless mausoleum of documentation.

Use at your own risk. If thy machine shudders, weeps, or attempts to flee - know that it was warned.

## Vulkan 1.0 specification

<details>
    <summary>
        The present standing of thy Vulkan 1.0 specification's implementation
    </summary>

\
⚠️ Implemented, yet perchance not fully tested nor proven conformant, but rather working in a manner most general to thee and thine.\
Assume thou that functions lacking in this array are, for now, not intended to be wrought.

Name                                             | Status
-------------------------------------------------|--------
vkAcquireNextImageKHR                            | ⚙️ WIP
vkAllocateCommandBuffers                         | ✅ Implemented
vkAllocateDescriptorSets                         | ✅ Implemented
vkAllocateMemory                                 | ✅ Implemented
vkBeginCommandBuffer                             | ✅ Implemented
vkBindBufferMemory                               | ✅ Implemented
vkBindImageMemory                                | ✅ Implemented
vkCmdBeginQuery                                  | ⚙️ WIP
vkCmdBeginRenderPass                             | ✅ Implemented
vkCmdBindDescriptorSets                          | ✅ Implemented
vkCmdBindIndexBuffer                             | ✅ Implemented
vkCmdBindPipeline                                | ✅ Implemented
vkCmdBindVertexBuffers                           | ✅ Implemented
vkCmdBlitImage                                   | ✅ Implemented
vkCmdClearAttachments                            | ✅ Implemented
vkCmdClearColorImage                             | ✅ Implemented
vkCmdClearDepthStencilImage                      | ⚙️ WIP
vkCmdCopyBuffer                                  | ✅ Implemented
vkCmdCopyBufferToImage                           | ✅ Implemented
vkCmdCopyImage                                   | ✅ Implemented
vkCmdCopyImageToBuffer                           | ✅ Implemented
vkCmdCopyQueryPoolResults                        | ⚙️ WIP
vkCmdDispatch                                    | ✅ Implemented
vkCmdDispatchIndirect                            | ✅ Implemented
vkCmdDraw                                        | ✅ Implemented
vkCmdDrawIndexed                                 | ✅ Implemented
vkCmdDrawIndexedIndirect                         | ✅ Implemented
vkCmdDrawIndirect                                | ✅ Implemented
vkCmdEndQuery                                    | ⚙️ WIP
vkCmdEndRenderPass                               | ✅ Implemented
vkCmdExecuteCommands                             | ✅ Implemented
vkCmdFillBuffer                                  | ✅ Implemented
vkCmdNextSubpass                                 | ⚙️ WIP
vkCmdPipelineBarrier                             | ✅ Implemented
vkCmdPushConstants                               | ⚙️ WIP
vkCmdResetEvent                                  | ✅ Implemented
vkCmdResetQueryPool                              | ⚙️ WIP
vkCmdResolveImage                                | ⚙️ WIP
vkCmdSetBlendConstants                           | ⚙️ WIP
vkCmdSetDepthBias                                | ⚙️ WIP
vkCmdSetDepthBounds                              | ⚙️ WIP
vkCmdSetEvent                                    | ✅ Implemented
vkCmdSetLineWidth                                | ⚙️ WIP
vkCmdSetScissor                                  | ⚙️ WIP
vkCmdSetStencilCompareMask                       | ⚙️ WIP
vkCmdSetStencilReference                         | ⚙️ WIP
vkCmdSetStencilWriteMask                         | ⚙️ WIP
vkCmdSetViewport                                 | ✅ Implemented
vkCmdUpdateBuffer                                | ⚙️ WIP
vkCmdWaitEvents                                  | ✅ Implemented
vkCmdWriteTimestamp                              | ⚙️ WIP
vkCreateBuffer                                   | ✅ Implemented
vkCreateBufferView                               | ⚙️ WIP
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
vkCreateQueryPool                                | ⚙️ WIP
vkCreateRenderPass                               | ✅ Implemented
vkCreateSampler                                  | ⚙️ WIP
vkCreateSemaphore                                | ⚙️ WIP
vkCreateShaderModule                             | ✅ Implemented
vkCreateSwapchainKHR                             | ⚙️ WIP
vkCreateSwapchainKHR                             | ✅ Implemented
vkCreateWaylandSurfaceKHR                        | ✅ Implemented
vkCreateWin32SurfaceKHR                          | ⚙️ WIP
vkCreateXcbSurfaceKHR                            | ⚙️ WIP
vkCreateXlibSurfaceKHR                           | ⚙️ WIP
vkDestroyBuffer                                  | ✅ Implemented
vkDestroyBufferView                              | ⚙️ WIP
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
vkDestroySwapchainKHR                            | ⚙️ WIP
vkDestroySwapchainKHR                            | ✅ Implemented
vkDeviceWaitIdle                                 | ✅ Implemented
vkEndCommandBuffer                               | ✅ Implemented
vkEnumerateDeviceExtensionProperties             | ⚙️ WIP
vkEnumerateDeviceLayerProperties                 | ⚙️ WIP
vkEnumerateInstanceExtensionProperties           | ⚙️ WIP
vkEnumerateInstanceLayerProperties               | ⚙️ WIP
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
vkGetImageSparseMemoryRequirements               | ⚙️ WIP
vkGetImageSubresourceLayout                      | ✅ Implemented
vkGetInstanceProcAddr                            | ✅ Implemented
vkGetPhysicalDeviceFeatures                      | ✅ Implemented
vkGetPhysicalDeviceFormatProperties              | ✅ Implemented
vkGetPhysicalDeviceImageFormatProperties         | ✅ Implemented
vkGetPhysicalDeviceMemoryProperties              | ✅ Implemented
vkGetPhysicalDeviceProperties                    | ✅ Implemented
vkGetPhysicalDeviceQueueFamilyProperties         | ✅ Implemented
vkGetPhysicalDeviceSparseImageFormatProperties   | ⚙️ WIP
vkGetPhysicalDeviceSurfaceCapabilitiesKHR        | ⚙️ WIP
vkGetPhysicalDeviceSurfaceFormatsKHR             | ⚙️ WIP
vkGetPhysicalDeviceSurfacePresentModesKHR        | ⚙️ WIP
vkGetPhysicalDeviceSurfaceSupportKHR             | ⚙️ WIP
vkGetPhysicalDeviceWaylandPresentationSupportKHR | ⚙️ WIP
vkGetPhysicalDeviceWind32PresentationSupportKHR  | ⚙️ WIP
vkGetPhysicalDeviceXcbPresentationSupportKHR     | ⚙️ WIP
vkGetPhysicalDeviceXlibPresentationSupportKHR    | ⚙️ WIP
vkGetPipelineCacheData                           | ⚙️ WIP
vkGetQueryPoolResults                            | ⚙️ WIP
vkGetRenderAreaGranularity                       | ⚙️ WIP
vkGetSwapchainImagesKHR                          | ⚙️ WIP
vkInvalidateMappedMemoryRanges                   | ✅ Implemented
vkMapMemory                                      | ✅ Implemented
vkMergePipelineCaches                            | ⚙️ WIP
vkQueueBindSparse                                | ⚙️ WIP
vkQueuePresentKHR                                | ⚙️ WIP
vkQueueSubmit                                    | ✅ Implemented
vkQueueWaitIdle                                  | ✅ Implemented
vkResetCommandBuffer                             | ✅ Implemented
vkResetCommandPool                               | ✅ Implemented
vkResetDescriptorPool                            | ✅ Implemented
vkResetEvent                                     | ✅ Implemented
vkResetFences                                    | ✅ Implemented
vkSetEvent                                       | ✅ Implemented
vkUnmapMemory                                    | ✅ Implemented
vkUpdateDescriptorSets                           | ✅ Implemented
vkWaitForFences                                  | ✅ Implemented
</details>

[Here](https://vulkan-driver-cts-report.kbz8.me/) shalt thou find a most meticulous account of the Vulkan 1.0 conformance trials, set forth for thy scrutiny.

## License

Released unto the world as MIT for study, experimentation, and the occasional horrified whisper.
Do with it as thou wilt, but accept the consequences as thine own.
