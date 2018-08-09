//
//  Renderer.swift
//  Seascape
//
//  Created by João Varela on 05/08/2018.
//  Copyright © 2018 João Varela. All rights reserved.
//

// Our platform independent renderer class

import MetalKit
import simd

class Renderer: NSObject, MTKViewDelegate
{
    // time
    let timeStep = Float(1.0/60.0)
    var time = Float(0)
    
    // mouse
    var mouse = NSPoint(x: 0, y: 0)
    
    public let device: MTLDevice
    
    // private ivars for triple buffering
    private let textureCount = 3
    private var textureQueue:[MTLTexture]!
    private var currentTexture:MTLTexture!
    
    // other ivars
    private var view:MTKView
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLComputePipelineState!
    private var inputBuffer: MTLBuffer!
    private var semaphore: DispatchSemaphore!
    
    // ---------------------------------------------------------------------------------
    // init
    // ---------------------------------------------------------------------------------
    init?(metalKitView: MTKView)
    {
        self.device = metalKitView.device!
        self.commandQueue = device.makeCommandQueue()!
        self.view = metalKitView
        self.textureQueue = []
        super.init()
        self.pipelineState = createPipeline()
        guard let layer = metalKitView.layer as? CAMetalLayer else { fatalError() }
        createScreenTextures(size: metalKitView.drawableSize, scale: layer.contentsScale)
        self.semaphore = DispatchSemaphore(value: textureCount)
    }
    
    // ---------------------------------------------------------------------------------
    // createPipeline
    // ---------------------------------------------------------------------------------
    private func createPipeline() -> MTLComputePipelineState?
    {
        let library = device.makeDefaultLibrary()!
        
        do {
            if let kernel = library.makeFunction(name: "compute")
            {
                self.inputBuffer = device.makeBuffer(length: MemoryLayout<float4>.size, options: [])
                return try device.makeComputePipelineState(function: kernel)
            }
            else
            {
                view.printView("Setting pipeline state failed")
            }
        }
            
        catch let error {
            view.printView("\(error)")
        }
        
        return nil
    }
    
    // ---------------------------------------------------------------------------------
    // createScreenTextures
    // ---------------------------------------------------------------------------------
    private func createScreenTextures(size:CGSize, scale:CGFloat)
    {
        textureQueue.removeAll()
        currentTexture = nil
        guard let metalLayer = view.layer as? CAMetalLayer else { fatalError() }
        let pixelformat = metalLayer.pixelFormat
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelformat,
                                                                  width: Int(size.width),
                                                                  height: Int(size.height),
                                                                  mipmapped: false)
        
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        for i in 0..<textureCount
        {
            guard let texture = device.makeTexture(descriptor: descriptor) else { fatalError() }
            texture.label = "Seascape #\(i)"
            textureQueue.append(texture)
        }
    }
    
    // ---------------------------------------------------------------------------------
    // draw
    // ---------------------------------------------------------------------------------
    func draw(in view: MTKView)
    {
        _ = semaphore.wait(timeout: .distantFuture)
        time += timeStep
        let inputBufferPtr = inputBuffer.contents().bindMemory(to: float4.self, capacity: 1)
        inputBufferPtr.pointee = float4(Float(mouse.x),Float(mouse.y),0.0,time)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let blockSemaphore = semaphore
        commandBuffer.addCompletedHandler({_ in blockSemaphore?.signal()})
        encodeCompute(commandBuffer)
        
        if let drawable = view.currentDrawable
        {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
    
    // ---------------------------------------------------------------------------------
    // encodeCompute
    // ---------------------------------------------------------------------------------
    private func encodeCompute(_ commandBuffer:MTLCommandBuffer)
    {
        guard let writeTexture = textureQueue.first else { fatalError() }
        guard let commandEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        commandEncoder.setComputePipelineState(pipelineState)
        commandEncoder.setTexture(currentTexture, index: 0)
        commandEncoder.setTexture(writeTexture, index: 1)
        commandEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        let w = pipelineState.threadExecutionWidth
        let h = pipelineState.maxTotalThreadsPerThreadgroup / w;
        let threadGroupCount = MTLSize(width: w, height: h, depth: 1)
        let threadGroups = MTLSize(width: (writeTexture.width + w - 1) / w,
                                   height: (writeTexture.height + h - 1) / h,
                                   depth: 1)
        commandEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupCount)
        commandEncoder.endEncoding()
        rotateTextures()
    }
    
    // ---------------------------------------------------------------------------------
    // mtkView(_:drawableSizeWillChange)
    // ---------------------------------------------------------------------------------
    // Callback when the user changes the size of the window
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    {
        guard let scale = view.layer?.contentsScale else { return }
        createScreenTextures(size: size, scale: scale)
    }
    
    // ---------------------------------------------------------------------------------
    // rotateTextures                                                         private
    // ---------------------------------------------------------------------------------
    // rotate the texture queue
    private func rotateTextures()
    {
        currentTexture = textureQueue.first
        textureQueue.remove(at: 0)
        textureQueue.append(currentTexture)
    }
}

