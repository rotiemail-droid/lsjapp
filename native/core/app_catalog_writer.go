package core

import (
	"encoding/json"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type nativeCatalogWriter struct {
	mu sync.Mutex
	wake chan struct{}
	force chan struct{}
	changed chan struct{}
	revision uint64
	saved uint64
	firstDirty time.Time
}

func (engine *nativeEngine) catalogWriterLocked() *nativeCatalogWriter {
	if engine.catalogWriter == nil {
		engine.catalogWriter = &nativeCatalogWriter{wake: make(chan struct{}, 1), force: make(chan struct{}, 1), changed: make(chan struct{})}
		go engine.runCatalogWriter(engine.catalogWriter)
	}
	return engine.catalogWriter
}

func (engine *nativeEngine) touchCatalogLocked(key string) {
	if engine.catalogRevisions == nil {
		engine.catalogRevisions = make(map[string]uint64)
	}
	engine.catalogRevisions[key]++
	delete(engine.catalogSummaries, key)
}
func (engine *nativeEngine) queueCatalogSaveLocked() error {
	if engine.deferCatalogSave {
		engine.markCatalogSavePendingLocked()
		return nil
	}
	writer := engine.catalogWriterLocked()
	writer.revision++
	if writer.firstDirty.IsZero() {
		writer.firstDirty = time.Now()
		engine.markCatalogSavePendingLocked()
	}
	select {
	case writer.wake <- struct{}{}:
	default:
	}
	return engine.catalogSaveError
}

func (engine *nativeEngine) catalogSnapshotLocked() nativeCatalogDisk {
	disk := nativeCatalogDisk{Version: 3, Catalogs: make(map[string][]nativeDrama, len(engine.catalogs)), States: make(map[string]nativeCatalogState, len(engine.catalogStates)), Categories: make(map[string][]nativeCategory, len(engine.categoryOptions)), HongguoApp: cloneHongguoCatalogState(engine.hongguoCatalog), Recommendations: make(map[string]nativeRecommendationState, len(engine.recommendations))}
	for key, items := range engine.catalogs {
		disk.Catalogs[key] = items
	}
	for key, state := range engine.catalogStates {
		disk.States[key] = state
	}
	for key, items := range engine.categoryOptions {
		disk.Categories[key] = items
	}
	for key, state := range engine.recommendations {
		disk.Recommendations[key] = state
	}
	return disk
}

func (engine *nativeEngine) runCatalogWriter(writer *nativeCatalogWriter) {
	for {
		select {
		case <-writer.wake:
			engine.mu.Lock()
			delay := time.Until(writer.firstDirty.Add(5 * time.Second))
			engine.mu.Unlock()
			if delay > time.Second {
				delay = time.Second
			}
			if delay > 0 {
				timer := time.NewTimer(delay)
				select {
				case <-timer.C:
				case <-writer.force:
					if !timer.Stop() {
						select { case <-timer.C: default: }
					}
				}
			}
		case <-writer.force:
		}
		engine.saveQueuedCatalog(writer)
	}
}

func (engine *nativeEngine) saveQueuedCatalog(writer *nativeCatalogWriter) {
	engine.mu.Lock()
	if writer.saved == writer.revision {
		engine.mu.Unlock()
		return
	}
	revision := writer.revision
	disk := engine.catalogSnapshotLocked()
	engine.mu.Unlock()
	body, err := json.Marshal(disk)
	if err == nil && len(body) > nativeCatalogMaxBytes {
		err = errNativeCatalogLimit
	}
	if err == nil {
		err = writeNativeCacheFile(filepath.Join(engine.directory, "catalogs.json"), body)
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	engine.catalogSaveError = nativeSaveError("剧库", err)
	if err == nil {
		writer.saved = revision
		if writer.saved == writer.revision {
			writer.firstDirty = time.Time{}
			engine.finishCatalogSaveLocked()
		}
	} else {
		engine.markCatalogSavePendingLocked()
	}
	close(writer.changed)
	writer.changed = make(chan struct{})
}

func (engine *nativeEngine) flushCatalogSave() error {
	engine.mu.Lock()
	writer := engine.catalogWriter
	if writer == nil || writer.saved == writer.revision {
		err := engine.catalogSaveError
		engine.mu.Unlock()
		return err
	}
	target := writer.revision
	for {
		changed := writer.changed
		select { case writer.force <- struct{}{}: default: }
		engine.mu.Unlock()
		<-changed
		engine.mu.Lock()
		if writer.saved >= target || engine.catalogSaveError != nil {
			err := engine.catalogSaveError
			engine.mu.Unlock()
			return err
		}
	}
}

type nativeCatalogSummary struct {
	Revision string `json:"revision"`
	Count int `json:"count"`
	Page int `json:"page"`
	HasMore bool `json:"hasMore"`
	Fresh bool `json:"fresh"`
	Warning string `json:"warning"`
	LocalCategories []string `json:"localCategories"`
}

func (engine *nativeEngine) catalogSummaryLocked(key string) nativeCatalogSummary {
	if engine.catalogSummaries == nil {
		engine.catalogSummaries = make(map[string][]string)
	}
	categories, found := engine.catalogSummaries[key]
	if !found {
		seen := make(map[string]bool)
		categories = []string{}
		for _, item := range engine.catalogs[key] {
			name := strings.TrimSpace(item.Category)
			if name != "" && !seen[name] {
				seen[name] = true
				categories = append(categories, name)
			}
		}
		engine.catalogSummaries[key] = categories
	}
	state, tracked := engine.catalogStates[key]
	age := time.Since(state.UpdatedAt)
	summary := nativeCatalogSummary{Revision: strconv.FormatUint(engine.catalogRevisions[key], 10), Count: len(engine.catalogs[key]), Page: max(1, state.Page), HasMore: !tracked || state.HasMore, Fresh: len(engine.catalogs[key]) > 0 && state.Warning == "" && !state.UpdatedAt.IsZero() && age >= 0 && age < nativeCatalogTTL, Warning: state.Warning, LocalCategories: categories}
	if engine.catalogSaveError != nil {
		summary.Warning = joinNativeWarnings(summary.Warning, engine.catalogSaveError.Error())
		summary.Fresh, summary.HasMore = false, true
	}
	return summary
}

func (engine *nativeEngine) nativeCatalogSummary(source, category string) nativeCatalogSummary {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	return engine.catalogSummaryLocked(nativeCatalogKey(source, category))
}
